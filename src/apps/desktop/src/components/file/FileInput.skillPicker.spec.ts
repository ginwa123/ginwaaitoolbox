/**
 * FileInput `/skill` picker — trigger, fetch-once, filter, insert, error.
 *
 * Contract under test:
 *   - Typing `/skill` opens the picker and calls `api.getSkills(ws)` ONCE
 *     per workspace per mount (client-side substring filter after that —
 *     no refetch while typing past the dash).
 *   - Enter inserts the typed form (`/skill-<name>` for the namespace
 *     form), Esc closes without inserting.
 *   - A `getSkills` rejection renders the error block, never an empty list.
 *   - With no workspace scope (or no pinia) `/` does not open.
 *   - `/` must be at message start or after whitespace — `http://` and
 *     `a/b` never match.
 */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from './FileInput.vue'
import * as api from '../../api'
import { useWorkspacesStore, type Workspace } from '../../stores/workspaces'

vi.mock('../../api', () => ({
  API_BASE: '/api',
  searchFiles: vi.fn(),
  getSkills: vi.fn(),
}))

const getSkillsMock = api.getSkills as unknown as ReturnType<typeof vi.fn>
const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>

const WS_ID = 'ws_1'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: 'folder', items: [], expanded: true } satisfies Workspace,
  ]
}

function skillsPayload() {
  return {
    skills: [
      { name: 'review', description: 'reviews code' },
      { name: 'deploy', description: 'deploys the app' },
    ],
  }
}

async function mountInput(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

/**
 * Set the textarea value, park the cursor at the end, dispatch `input`
 * so `autoResize` updates `cursorPos`, then wait out the 150ms
 * detect debounce plus promise flushes.
 */
async function typeInTextarea(
  textareaWrapper: ReturnType<VueWrapper['find']>,
  value: string,
  waitMs = 450,
) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  await new Promise((resolve) => setTimeout(resolve, waitMs))
  await flushPromises()
}

describe('FileInput — /skill picker', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    getSkillsMock.mockReset()
    searchFilesMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
    getSkillsMock.mockResolvedValue(skillsPayload())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("typing '/skill' opens the picker and calls getSkills once", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill')

    expect(getSkillsMock).toHaveBeenCalledTimes(1)
    expect(getSkillsMock).toHaveBeenCalledWith(WS_ID)
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skill-picker-list"]').text()).toContain('review')
  })

  it('typing past the dash filters client-side without refetching', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill')

    expect(getSkillsMock).toHaveBeenCalledTimes(1)

    await typeInTextarea(textarea, '/skill-dep')
    expect(getSkillsMock).toHaveBeenCalledTimes(1)
    const list = wrapper.find('[data-testid="skill-picker-list"]')
    expect(list.text()).toContain('deploy')
    expect(list.text()).not.toContain('review')
  })

  it("Enter inserts '/skill-<name>' as plain text", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-dep')
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('/skill-deploy')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
  })

  it('Esc closes the picker without inserting', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Escape' })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('/skill')
  })

  it('getSkills rejection renders the error block, never an empty list', async () => {
    seedWorkspace()
    getSkillsMock.mockRejectedValue(new Error('backend down'))
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill')

    const error = wrapper.find('[data-testid="skill-picker-error"]')
    expect(error.exists()).toBe(true)
    expect(error.text()).toContain('backend down')
    expect(wrapper.find('[data-testid="skill-picker-list"]').text()).not.toContain(
      'No skills found',
    )
  })

  it('no workspace -> `/` does not open and getSkills is not called', async () => {
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill')

    expect(getSkillsMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
  })

  it('a slash inside a URL or path never opens the picker', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, 'see http://example.com/x')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)

    await typeInTextarea(textarea, 'see a/b')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    expect(getSkillsMock).not.toHaveBeenCalled()
  })
})
