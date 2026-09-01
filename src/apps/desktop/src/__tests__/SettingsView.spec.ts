import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import SettingsView from '../components/views/SettingsView.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('../api', () => ({
  getChats: vi.fn().mockResolvedValue({ sessions: [], has_more: false, next_cursor: null, total: 0 }),
  getLlmHistory: vi.fn().mockResolvedValue({ session_id: '', model: '', url_style: '', chain: [], curl: { anthropic: '', openai: '', openai_response: '' }, bodies: { anthropic: null, openai: null, openai_response: null } }),
  getNalarConfig: vi.fn().mockResolvedValue({}),
  saveNalarConfig: vi.fn().mockResolvedValue({ success: true }),
  deleteProfile: vi.fn().mockResolvedValue({ success: true }),
  getSkills: vi.fn().mockResolvedValue({ global_skills: [], local_skills: [] }),
  getSkillDetail: vi.fn().mockResolvedValue({ skill: null, error_message: null }),
  getMemories: vi.fn().mockResolvedValue({ memories: [] }),
  getMemoryDetail: vi.fn().mockResolvedValue({ memory: null, error_message: null }),
}))

const mockRouter = { back: vi.fn(), replace: vi.fn(), push: vi.fn() }
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => mockRouter,
  }
})

describe('SettingsView', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('renders 4 sidebar tabs: Nalar, Skills, Memories, LLM History', async () => {
    const wrapper = mount(SettingsView, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()

    const tabButtons = wrapper.findAll('nav button')
    const labels = tabButtons.map(b => b.text().trim().replace(/\s+/g, ' '))
    // Emoji + text are adjacent spans — normalize whitespace for comparison
    const normalized = labels.map(l => l.replace(/([^\s])Nalar/, '$1 Nalar').replace(/([^\s])Skills/, '$1 Skills').replace(/([^\s])Memories/, '$1 Memories').replace(/([^\s])LLM/, '$1 LLM'))
    // Simpler: just check each label contains the expected keyword
    expect(labels[0]).toContain('Nalar')
    expect(labels[1]).toContain('Skills')
    expect(labels[2]).toContain('Memories')
    expect(labels[3]).toContain('LLM History')
    expect(normalized).toHaveLength(4)
    wrapper.unmount()
  })

  it('has 4th tab with data-testid settings-tab-llm-history', async () => {
    const wrapper = mount(SettingsView, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="settings-tab-llm-history"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('clicking LLM History tab mounts the inspector', async () => {
    const wrapper = mount(SettingsView, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()

    // Initially Nalar tab is active — no inspector
    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(false)

    await wrapper.find('[data-testid="settings-tab-llm-history"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('other tabs still work after adding 4th tab', async () => {
    const wrapper = mount(SettingsView, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()

    const navButtons = wrapper.findAll('nav button')
    // Find Skills button
    const skillsBtn = navButtons.find(b => b.text().includes('Skills'))
    expect(skillsBtn).toBeDefined()
    await skillsBtn!.trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(false)

    // Click Memories
    const memoriesBtn = navButtons.find(b => b.text().includes('Memories'))
    await memoriesBtn!.trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(false)

    // Click LLM History
    await wrapper.find('[data-testid="settings-tab-llm-history"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(true)

    // Back to Nalar
    const nalarBtn = navButtons.find(b => b.text().includes('Nalar'))
    await nalarBtn!.trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('defaults to Nalar tab on mount', async () => {
    const wrapper = mount(SettingsView, {
      global: { stubs: { Teleport: true } },
    })
    await flushPromises()

    expect(wrapper.find('[data-testid="llm-history-settings"]').exists()).toBe(false)
    const nalarBtn = wrapper.findAll('nav button')[0]!
    expect(nalarBtn.attributes('style')).toContain('var(--semantic-active-bg)')
    wrapper.unmount()
  })
})
