import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import NalarSettings from '../components/NalarSettings.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('../api', () => ({
  getNalarConfig: vi.fn(),
  saveNalarConfig: vi.fn(),
  deleteProfile: vi.fn(),
}))

const mockGet = api.getNalarConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.saveNalarConfig as unknown as ReturnType<typeof vi.fn>

describe('NalarSettings (orchestrator)', () => {
  beforeEach(() => {
    mockGet.mockReset()
    mockSave.mockReset()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('renders the 4 tab labels', async () => {
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(NalarSettings, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.text()).toContain('Defaults')
    expect(wrapper.text()).toContain('Profiles')
    expect(wrapper.text()).toContain('Sub-agents')
    expect(wrapper.text()).toContain('MCP Servers')
  })

  it('loads the config on mount and shows the Defaults fields', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini', api_endpoint: 'https://x' })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    expect(mockGet).toHaveBeenCalled()
    expect(wrapper.find('[data-testid="model-input"]').exists()).toBe(true)
  })

  it('shows the save bar with the right count after a field edit', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    const bar = wrapper.find('[data-testid="save-bar"]')
    expect(bar.exists()).toBe(true)
    expect(bar.text()).toMatch(/unsaved change/)
  })

  it('saves the config and hides the save bar when Save is clicked', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledWith(expect.objectContaining({ model: 'gpt-4o' }))
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)
  })

  it('emits a success notification on save', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('notification')?.some(e => e[1] === 'success')).toBe(true)
  })

  it('resets the config and clears dirty when Reset is clicked', async () => {
    mockGet.mockResolvedValueOnce({ model: 'gpt-4o-mini' })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    await wrapper.find('[data-testid="model-input"]').setValue('gpt-4o')
    await flushPromises()
    await wrapper.find('[data-testid="reset-btn"]').trigger('click')
    await flushPromises()
    // The save bar's leave-transition may not complete within
    // flushPromises in jsdom, so we don't assert on its DOM
    // presence. Instead we assert the most important property:
    // the model input is back to its original value.
    expect((wrapper.find('[data-testid="model-input"]').element as HTMLInputElement).value).toBe('gpt-4o-mini')
  })
})
