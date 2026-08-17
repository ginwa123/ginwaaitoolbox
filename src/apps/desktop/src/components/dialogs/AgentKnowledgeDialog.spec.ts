// Behavioural tests for AgentKnowledgeDialog.

import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AgentKnowledgeDialog from './AgentKnowledgeDialog.vue'

describe('AgentKnowledgeDialog', () => {
  it('shows the "Add Knowledge" title when show=true', async () => {
    const wrapper = mount(AgentKnowledgeDialog, { props: { show: true } })
    await nextTick()
    const dialog = wrapper.find('[data-testid="agent-knowledge-dialog"]').element as HTMLElement | null
    expect(dialog?.textContent).toContain('Add Knowledge')
  })

  it('disables submit when path is empty', async () => {
    const wrapper = mount(AgentKnowledgeDialog, { props: { show: true } })
    await nextTick()
    const submit = wrapper.find('[data-testid="agent-knowledge-submit"]')
    expect(submit.attributes('disabled')).toBeDefined()
  })

  it('shows an error for non-absolute paths after interaction', async () => {
    const wrapper = mount(AgentKnowledgeDialog, { props: { show: true } })
    await nextTick()
    const pathInput = wrapper.find('[data-testid="agent-knowledge-path"]')
    await pathInput.setValue('relative/path.md')
    await pathInput.trigger('blur')
    const error = wrapper.find('[data-testid="agent-knowledge-path-error"]')
    expect(error.exists()).toBe(true)
    expect(error.text()).toContain('absolute')
  })

  it('emits create with (file_path, label) when submit clicked with valid input', async () => {
    const wrapper = mount(AgentKnowledgeDialog, { props: { show: true } })
    await nextTick()
    await wrapper.find('[data-testid="agent-knowledge-path"]').setValue('/home/me/docs/spec.md')
    await wrapper.find('[data-testid="agent-knowledge-label"]').setValue('Project spec')
    await wrapper.find('[data-testid="agent-knowledge-submit"]').trigger('click')
    const events = wrapper.emitted('create')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual(['/home/me/docs/spec.md', 'Project spec'])
  })
})