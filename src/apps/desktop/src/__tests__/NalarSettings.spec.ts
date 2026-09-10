import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import NalarSettings from '../components/NalarSettings.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('../api', () => ({
  getNalarConfig: vi.fn(),
  saveNalarConfig: vi.fn(),
  deleteProfile: vi.fn(),
  // Plan 2026-09-10-web-launch-toggle: browser-mode status for the
  // General tab URL pill. Resolves null by default (pill waiting hint).
  getWebStatus: vi.fn(),
}))

const mockGet = api.getNalarConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.saveNalarConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>

describe('NalarSettings (orchestrator)', () => {
  beforeEach(() => {
    mockGet.mockReset()
    mockSave.mockReset()
    mockWebStatus.mockReset()
    mockWebStatus.mockResolvedValue(null)
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('renders the 3 tab labels in order: General / Profiles / MCP Servers (no global Sub-agents)', async () => {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // General tab is the FIRST tab. Tab order matters — operational
    // settings (notification toggles + retry delay) belong at the top.
    // Plan 2026-09-04-subagents-per-profile: the global Sub-agents tab
    // is removed — sub-agents live inside each profile row.
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(NalarSettings, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()
    const tabs = wrapper.findAll('button[role="tab"]').map(b => b.text().trim())
    expect(tabs).toEqual(['General', 'Profiles', 'MCP Servers'])
    expect(wrapper.text()).not.toContain('Defaults')
    expect(wrapper.find('[data-tab-id="sub-agents"]').exists()).toBe(false)
  })

  it('never mounts the global SubAgentsSection (per-profile lists are the only editor)', async () => {
    // Plan 2026-09-04-subagents-per-profile regression: the global
    // `subAgentsList` + `SubAgentsSection` mount are gone. Even with a
    // legacy top-level `sub_agents` payload, no global list renders.
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm' } },
      sub_agents: [{ name: 'legacy', model: 'm' }],
    })
    const wrapper = mount(NalarSettings, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="subagent-list"]').exists()).toBe(false)
    expect(wrapper.find('[data-tab-id="sub-agents"]').exists()).toBe(false)
  })

  it('lands on the General tab by default', async () => {
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // first-load tab is General — operational settings are the most
    // likely entry point for new users.
    mockGet.mockResolvedValueOnce({})
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    const activeTab = wrapper.find('button[role="tab"][data-active="true"]')
    expect(activeTab.exists()).toBe(true)
    expect(activeTab.text()).toBe('General')
  })

  it('loads the config on mount and shows the Profiles section', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'gpt-4o-mini', base_url: 'https://x' } },
    })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    expect(mockGet).toHaveBeenCalled()
    // Profiles is the landing tab — the profile name should be visible.
    expect(wrapper.text()).toContain('work')
  })

  it('does not send top-level LLM defaults in the PUT body (config-simplify)', async () => {
    mockGet.mockResolvedValueOnce({
      profiles: { work: { model: 'm1' } },
      notify_on_complete: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()
    // Switch to the Profiles tab. Plan 2026-08-25-notify-on-error
    // moved General to index 0; Profiles is now at index 1.
    const profileTab = wrapper.find('[data-tab-id="profiles"]')
    await profileTab.trigger('click')
    await flushPromises()
    // Edit a profile to make the form dirty.
    await wrapper.find('[data-testid="expand-btn-work"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    for (const key of ['api_endpoint', 'api_key', 'model', 'url_style', 'temperature', 'max_tokens', 'system_prompt']) {
      expect(savedConfig).not.toHaveProperty(key)
    }
    expect(savedConfig.profiles).toBeDefined()
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

    // Switch to the Profiles tab. Plan 2026-08-25-notify-on-error
    // moved General to index 0; Profiles is now at index 1.
    const profileTab = wrapper.find('[data-tab-id="profiles"]')
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
    // No top-level sub_agents list is ever sent (per-profile only).
    const topLevel = (savedConfig as Record<string, unknown>).sub_agents as Array<{ name: string }> | undefined
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

    // Switch to Profiles tab. Plan 2026-08-25-notify-on-error moved
    // General to index 0; Profiles is now at index 1.
    const profileTab = wrapper.find('[data-tab-id="profiles"]')
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

    const profileTab = wrapper.find('[data-tab-id="profiles"]')
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

    const profileTab = wrapper.find('[data-tab-id="profiles"]')
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

  // ─── General tab (plan 2026-08-25-notify-on-error-and-retry-ms-in-settings) ──
  //
  // Three operational settings live in the General tab:
  //   - `notify_on_complete` (existing config.json field)
  //   - `notify_on_error` (new field added by this plan)
  //   - `retry_delay_ms` (existing config.json field)
  //
  // Each one must (a) hydrate from the API response, (b) flip the
  // dirty pill when the user changes it, (c) round-trip through the
  // PUT body on save.

  it('hydrates the General tab from the loaded config (notify_on_complete + notify_on_error + retry_delay_ms)', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: true,
      notify_on_error: true,
      retry_delay_ms: 15000,
      web_launch_enabled: true,
    })
    mockWebStatus.mockResolvedValueOnce({
      enabled: true,
      running: true,
      url: 'http://127.0.0.1:51234/',
      port: 51234,
    })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // The General tab is the first tab and lands there by default.
    expect(wrapper.find('button[role="tab"][data-active="true"]').text()).toBe('General')
    // Both toggles reflect the loaded values.
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-complete"]').element as HTMLInputElement).checked,
    ).toBe(true)
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-error"]').element as HTMLInputElement).checked,
    ).toBe(true)
    // The retry-delay input is in seconds (15000 ms = 15 sec).
    expect(
      Number((wrapper.find('[data-testid="input-retry-delay-seconds"]').element as HTMLInputElement).value),
    ).toBe(15)
    // Plan 2026-09-10-web-launch-toggle: the web-launch toggle reflects
    // the loaded flag and the pill shows the live status URL.
    expect(
      (wrapper.find('[data-testid="toggle-web-launch"]').element as HTMLInputElement).checked,
    ).toBe(true)
    expect(wrapper.find('[data-testid="pill-web-url"]').text()).toContain('http://127.0.0.1:51234/')
  })

  it('toggling notify_on_error in the General tab flips dirty=true and round-trips through save', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // The save bar should be hidden (dirty=false on first load).
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)

    // Toggle notify_on_error ON.
    const toggle = wrapper.find('[data-testid="toggle-notify-on-error"]')
    await toggle.setValue(true)
    await flushPromises()

    // Now the dirty pill should appear.
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(true)

    // Click Save — the PUT body must carry notify_on_error: true.
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.notify_on_error).toBe(true)
    // The other operational settings should also be in the body
    // (syncToConfig writes them through unconditionally — now four).
    expect(savedConfig.notify_on_complete).toBe(false)
    expect(savedConfig.retry_delay_ms).toBe(0)
    expect(savedConfig.web_launch_enabled).toBe(false)
  })

  it('typing into the retry-delay input round-trips to retry_delay_ms in the PUT body', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Set the retry delay to 5 seconds → backend expects 5000 ms.
    const input = wrapper.find('[data-testid="input-retry-delay-seconds"]')
    await input.setValue('5')
    await flushPromises()

    // Save.
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.retry_delay_ms).toBe(5000)
  })

  it('clamps retry-delay input values to [0, 60] seconds in the General tab', async () => {
    // The backend caps retry_delay_ms at 60_000 (nalar_config_put.zig).
    // The UI clamps at the same range so the user gets immediate
    // feedback instead of a silent server-side clamp.
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    const input = wrapper.find('[data-testid="input-retry-delay-seconds"]')

    // Above-max → clamps to 60 seconds (the underlying value should
    // be 60_000 ms — assert via the ms readout element's text
    // content, which is the source of truth the user sees).
    await input.setValue('999')
    await flushPromises()
    // The input element's `.value` is a string — vitest sometimes
    // formats numbers with locale separators, so check via the
    // dedicated ms-readout element instead.
    const msReadout = wrapper.find('[data-testid="retry-delay-ms-readout"]')
    expect(msReadout.text()).toContain('60000')

    // Below-min (negative) → clamps to 0.
    await input.setValue('-5')
    await flushPromises()
    expect(msReadout.text()).toContain('0')
  })

  it('the PUT body always includes all four operational settings, even when the user only edits one', async () => {    // The General tab MUST write all four operational settings
    // through (syncToConfig does this unconditionally). This is a
    // regression guard so a future refactor doesn't accidentally
    // drop one of them and silently re-introduce the hidden-field
    // bug. Toggling ONLY `notify_on_error` must still surface the
    // other unchanged fields in the PUT body.
    mockGet.mockResolvedValueOnce({
      notify_on_complete: true,
      notify_on_error: false,
      retry_delay_ms: 10000,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    // Toggle ONLY notify_on_error.
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await flushPromises()

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
    expect(savedConfig.notify_on_complete).toBe(true)
    expect(savedConfig.notify_on_error).toBe(true)
    expect(savedConfig.retry_delay_ms).toBe(10000)
    expect(savedConfig.web_launch_enabled).toBe(false)
  })

  // ─── Web launch toggle (plan 2026-09-10-web-launch-toggle) ──
  it('toggling web-launch ON and saving PUTs web_launch_enabled:true and auto-opens the status URL', async () => {
    mockGet.mockResolvedValueOnce({
      notify_on_complete: false,
      notify_on_error: false,
      retry_delay_ms: 0,
      web_launch_enabled: false,
    })
    mockSave.mockResolvedValueOnce({ success: true })
    // Two status fetches happen: one on mount (pill), one after save
    // (auto-open). Queue the URL for both.
    mockWebStatus.mockResolvedValueOnce({
      enabled: false,
      running: true,
      url: 'http://127.0.0.1:51234/',
      port: 51234,
    })
    mockWebStatus.mockResolvedValueOnce({
      enabled: true,
      running: true,
      url: 'http://127.0.0.1:51234/',
      port: 51234,
    })
    const openSpy = vi.fn()
    const prevOpen = window.open
    window.open = openSpy as unknown as typeof window.open
    try {
      const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
      await flushPromises()

      await wrapper.find('[data-testid="toggle-web-launch"]').setValue(true)
      await flushPromises()
      await wrapper.find('[data-testid="save-btn"]').trigger('click')
      await flushPromises()

      expect(mockSave).toHaveBeenCalledTimes(1)
      const savedConfig = mockSave.mock.calls[0]![0] as Record<string, unknown>
      expect(savedConfig.web_launch_enabled).toBe(true)
      // OFF→ON transition + known URL → one auto-open from the Save
      // gesture (popup-blocker safe).
      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(openSpy).toHaveBeenCalledWith('http://127.0.0.1:51234/', '_blank', 'noopener')
    } finally {
      window.open = prevOpen
    }
  })

  // ─── MCP server enabled toggle (orchestrator) ──
  it('toggling a server off writes enabled:false for that server in the PUT body', async () => {
    mockGet.mockResolvedValueOnce({
      mcp_servers: {
        ctx7: { url: 'https://mcp.context7.com/mcp' },
        hello: { command: 'mcp-hello-world' },
      },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    await wrapper.find('[data-tab-id="mcp"]').trigger('click')
    await flushPromises()

    const toggles = wrapper.findAll('[data-testid="toggle-btn"]')
    expect(toggles).toHaveLength(2)
    // Rows sort by name: ctx7 first, hello second. Disable hello.
    await toggles[1]!.trigger('click')
    await flushPromises()

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, Record<string, unknown>>
    const servers = savedConfig.mcp_servers as Record<string, Record<string, unknown>>
    expect(servers.hello).toMatchObject({ enabled: false })
    // The untouched server stays omit-when-true (no enabled key).
    expect(servers.ctx7).not.toHaveProperty('enabled')
  })

  it('toggling a disabled server back on drops the enabled key (omit-when-true)', async () => {
    mockGet.mockResolvedValueOnce({
      mcp_servers: {
        hello: { command: 'mcp-hello-world', enabled: false },
      },
    })
    mockSave.mockResolvedValueOnce({ success: true })
    const wrapper = mount(NalarSettings, { global: { stubs: { Teleport: true } } })
    await flushPromises()

    await wrapper.find('[data-tab-id="mcp"]').trigger('click')
    await flushPromises()

    await wrapper.find('[data-testid="toggle-btn"]').trigger('click')
    await flushPromises()

    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    await flushPromises()
    expect(mockSave).toHaveBeenCalledTimes(1)
    const savedConfig = mockSave.mock.calls[0]![0] as Record<string, Record<string, unknown>>
    const servers = savedConfig.mcp_servers as Record<string, Record<string, unknown>>
    expect(servers.hello).not.toHaveProperty('enabled')
  })
})
