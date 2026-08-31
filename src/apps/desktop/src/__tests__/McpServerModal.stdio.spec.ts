import { mount, type VueWrapper } from '@vue/test-utils'
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
 * Both branches of McpServerModal use <Teleport to="body">: the HTTP
 * branch delegates to <LlmConfigModal>, the stdio branch has its own
 * bespoke centered dialog with backdrop + close ✕. Tests MUST use
 * `document.body.querySelector` for teleported elements (NOT
 * `wrapper.find`) and `mount({ attachTo: document.body })` so the
 * teleported DOM lands on the same body the queries walk.
 */
function mountModal(
  value: McpServerModalValue,
  mode: 'add' | 'edit' = 'add',
): VueWrapper {
  return mount(McpServerModal, {
    props: { modelValue: value, mode },
    attachTo: document.body,
  })
}

describe('McpServerModal — stdio transport', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Defensive: the Teleport-target content can survive between tests
    // if unmount() doesn't fully clean it. Force-remove both the
    // stdio modal's teleport-landmarks and the HTTP branch's
    // LlmConfigModal landmarks so each test starts from a fresh DOM.
    document.querySelectorAll(
      '[data-testid="stdio-modal-backdrop"], [data-testid="stdio-modal-dialog"], [role="dialog"]',
    ).forEach((el) => el.remove())
  })

  it('renders stdio fields inside a centered modal (teleported to body)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-backdrop"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="name-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="command-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="args-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="env-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="cwd-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="save-btn"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="cancel-btn"]')).not.toBeNull()
  })

  it('shows "Add MCP server" title in add mode, "Edit MCP server" in edit mode', async () => {
    wrapper = mountModal(baseStdioServer, 'add')
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')?.textContent).toContain('Add MCP server')

    wrapper.unmount()
    wrapper = null
    // Force-clear leftover DOM since we manually unmount before the next mount.
    document.querySelectorAll('[data-testid="stdio-modal-backdrop"], [data-testid="stdio-modal-dialog"]').forEach((el) => el.remove())

    wrapper = mountModal(baseStdioServer, 'edit')
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')?.textContent).toContain('Edit MCP server')
  })

  it('shows transport toggle with stdio branch active by default when transport=stdio', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    // The toggle itself is teleported to body too. Query via document.body.
    expect(document.body.querySelector('[data-testid="transport-toggle-stdio"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="transport-toggle-http"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="command-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="args-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="env-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="cwd-input"]')).not.toBeNull()
    // URL field (HTTP branch) MUST NOT be in the DOM — LlmConfigModal
    // uses 'base-url-input' and would teleport it to body if it were.
    expect(document.body.querySelector('[data-testid="base-url-input"]')).toBeNull()
  })

  it('shows URL + headers fields when transport=http', async () => {
    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    // HTTP branch teleports via LlmConfigModal. Document body has the
    // base-url-input (LlmConfigModal's data-testid) but the stdio
    // dialog landmarks are absent.
    expect(document.body.querySelector('[data-testid="base-url-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="stdio-modal-backdrop"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).toBeNull()
  })

  it('switching to HTTP hides the stdio dialog and shows the HTTP modal', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="base-url-input"]')).toBeNull()

    // Click the HTTP toggle button in the teleported DOM (native click).
    const httpBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="transport-toggle-http"]',
    )
    expect(httpBtn).not.toBeNull()
    httpBtn!.click()
    await wrapper.vm.$nextTick()

    // StdIO dialog unmounts; HTTP modal teleports (LlmConfigModal renders
    // its dialog via its own Teleport, but the stdio backdrop is gone).
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="base-url-input"]')).not.toBeNull()
  })

  it('emits cancel when the close ✕ button is clicked', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const closeBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="stdio-close-btn"]',
    )
    expect(closeBtn).not.toBeNull()
    closeBtn!.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('emits cancel when the backdrop is clicked (not on the dialog itself)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const backdrop = document.body.querySelector<HTMLElement>(
      '[data-testid="stdio-modal-backdrop"]',
    )
    expect(backdrop).not.toBeNull()
    backdrop!.click()   // click directly on the backdrop element
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('does NOT emit cancel when clicking on the dialog body (only on backdrop)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const dialog = document.body.querySelector<HTMLElement>(
      '[data-testid="stdio-modal-dialog"]',
    )!
    dialog.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeFalsy()
  })

  it('emits cancel when the footer Cancel button is clicked', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const cancelBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="cancel-btn"]',
    )!
    cancelBtn.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('rejects save when command is empty in stdio mode', async () => {
    wrapper = mountModal({ ...baseStdioServer, command: '' })
    await wrapper.vm.$nextTick()
    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    expect(saveBtn.disabled).toBe(true)
    saveBtn.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('save')).toBeFalsy()
  })

  it('emits save when Command is present and footer Save is clicked', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    expect(saveBtn.disabled).toBe(false)
    saveBtn.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('save')).toBeTruthy()
  })

  it('parses args textarea (newline-separated) on save', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const textarea = document.body.querySelector<HTMLTextAreaElement>(
      '[data-testid="args-textarea"]',
    )!
    // Native setter + dispatch 'input' to trigger v-model updates.
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype,
      'value',
    )!.set!
    setter.call(textarea, 'server.js\n--port\n3001')
    textarea.dispatchEvent(new Event('input'))
    await wrapper.vm.$nextTick()

    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    saveBtn.click()
    await wrapper.vm.$nextTick()

    // Modal emits the parsed args array back via update:modelValue
    // BEFORE the save event. The parent (NalarSettings.vue) sees
    // the parsed array on the modelValue and can persist it.
    const updates = wrapper.emitted('update:modelValue') ?? []
    const last = updates[updates.length - 1]?.[0] as McpServerModalValue | undefined
    expect(last).toBeTruthy()
    expect(last!.args).toEqual(['server.js', '--port', '3001'])
  })

  it('parses env textarea (KEY=VALUE per line) on save', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const textarea = document.body.querySelector<HTMLTextAreaElement>(
      '[data-testid="env-textarea"]',
    )!
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype,
      'value',
    )!.set!
    setter.call(textarea, 'NODE_ENV=production\nDEBUG=1')
    textarea.dispatchEvent(new Event('input'))
    await wrapper.vm.$nextTick()

    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    saveBtn.click()
    await wrapper.vm.$nextTick()

    const updates = wrapper.emitted('update:modelValue') ?? []
    const last = updates[updates.length - 1]?.[0] as McpServerModalValue | undefined
    expect(last).toBeTruthy()
    expect(last!.env).toEqual(['NODE_ENV=production', 'DEBUG=1'])
  })
})
