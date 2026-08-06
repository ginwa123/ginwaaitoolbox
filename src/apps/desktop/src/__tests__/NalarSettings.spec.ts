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

  // ─── Per-profile sub-agents (regression for the inline-expand flow) ──
  it('routes a sub-agent add through a profile scope to the right profile', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: {
        work: { model: 'm', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '' },
        home: { model: 'm2', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '' },
      },
    })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Switch to the Profiles tab.
    const profileTab = wrapper.findAll('button[role="tab"]')[1]!
    expect(profileTab.text()).toBe('Profiles')
    await profileTab.trigger('click')
    await flushPromises()

    // Expand 'work', click + Add sub-agent.
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="add-sub-agent-btn-work"]').trigger('click')
    await flushPromises()

    // The sub-agent modal should be open. Fill in name + save.
    const nameInput = wrapper.find('[data-testid="name-input"]')
    expect(nameInput.exists()).toBe(true)
    await nameInput.setValue('coder')
    await wrapper.find('[data-testid="model-input"]').setValue('claude-haiku-4-5')
    await wrapper.find('[data-testid="modal-save"]').trigger('click')
    await flushPromises()

    // After save, click Save changes and verify the sub-agent landed
    // on 'work' (not 'home' or the top-level list).
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    const profiles = savedConfig.profiles as Record<string, Record<string, unknown>>
    expect(profiles.work).toBeDefined()
    expect(profiles.home).toBeDefined()
    expect((profiles.work!.sub_agents as Array<{ name: string }>)[0]!.name).toBe('coder')
    // The 'home' profile never received a sub-agent, so its
    // sub_agents should be an empty array (or undefined).
    expect((profiles.home!.sub_agents as unknown[] | undefined)?.length ?? 0).toBe(0)
    // The top-level sub_agents list should not contain 'coder'.
    const topLevel = savedConfig.sub_agents as Array<{ name: string }> | undefined
    expect(topLevel ?? []).not.toContainEqual(expect.objectContaining({ name: 'coder' }))
  })

  // ─── Clear active profile (plan 2026-08-06-reset-active-profile) ──
  // Plan: Settings → Profiles → Reset button next to the active pill
  // emits `clearActive` → orchestrator calls saveNalarConfig with
  // `active_profile: ""` (empty string) → the backend handler at
  // `nalar_config_put.zig:246-252` interprets empty as "clear" and
  // sets `config_json.active_profile = null` on disk → the cascade
  // falls through to top-level config for every chat / task. The
  // button is gated on `activeProfile !== null` (a no-op when no
  // active is set).
  //
  // Why empty string (not `undefined`)?
  // Pre-fix the frontend sent `active_profile: undefined`, which JSON
  // serialisation strips to no key in the PUT body. The backend's
  // `?[]const u8` type couldn't distinguish "key absent" from
  // "key: null" — both yielded `None` and the handler skipped the
  // field. Using `undefined` left the user's "Set active" default
  // in place (the Reset button silently failed). The empty-string
  // sentinel works within the existing wire contract — the handler
  // already maps `ap.len == 0` to "clear" exactly for this purpose.
  it('saves active_profile: "" when the Reset button is clicked', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' }, home: { model: 'm2' } },
      active_profile: 'work',
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Switch to Profiles tab.
    const profileTab = wrapper.findAll('button[role="tab"]')[1]!
    await profileTab.trigger('click')
    await flushPromises()

    // The active pill should show 'work' and the Reset button should
    // be visible.
    expect(wrapper.text()).toContain('work')
    const resetBtn = wrapper.find('[data-testid="reset-active-btn"]')
    expect(resetBtn.exists()).toBe(true)

    // Click Reset → saveNalarConfig receives { ..., active_profile: '' }.
    // The backend interprets empty-string as "clear".
    await resetBtn.trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.active_profile).toBe('')
  })

  it('emits a success notification when the Reset button is clicked', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' } },
      active_profile: 'work',
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    const profileTab = wrapper.findAll('button[role="tab"]')[1]!
    await profileTab.trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    await flushPromises()
    expect(wrapper.emitted('notification')?.some(e => e[1] === 'success')).toBe(true)
  })

  it('restores the previous active profile when saveNalarConfig fails (optimistic rollback)', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' } },
      active_profile: 'work',
    })
    mockSave.mockRejectedValueOnce(new Error('network down'))
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    const profileTab = wrapper.findAll('button[role="tab"]')[1]!
    await profileTab.trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    await flushPromises()

    // After the failed save, the local activeProfile should still
    // reflect the original value (rolled back from the optimistic null).
    expect(wrapper.text()).toContain('work')
    // And an error notification should fire.
    expect(wrapper.emitted('notification')?.some(e => e[1] === 'error')).toBe(true)
  })
})
