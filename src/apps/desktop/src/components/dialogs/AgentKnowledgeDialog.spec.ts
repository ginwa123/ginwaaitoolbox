// Behavioural tests for AgentKnowledgeDialog.

import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AgentKnowledgeDialog from './AgentKnowledgeDialog.vue'

function mountDialog() {
  // The dialog uses <Teleport to="body">, so we attach to document.body
  // and search via document.querySelector. Same pattern as
  // AddAgentDialog.spec.ts.
  document.body.innerHTML = ''
  return mount(AgentKnowledgeDialog, {
    attachTo: document.body,
    props: { show: true },
  })
}

describe('AgentKnowledgeDialog', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the "Add Knowledge" title when show=true', async () => {
    mountDialog()
    await nextTick()
    const dialog = document.querySelector('[data-testid="agent-knowledge-dialog"]') as HTMLElement | null
    expect(dialog?.textContent).toContain('Add Knowledge')
  })

  it('disables submit when path is empty', async () => {
    mountDialog()
    await nextTick()
    const submit = document.querySelector('[data-testid="agent-knowledge-submit"]') as HTMLButtonElement
    expect(submit.hasAttribute('disabled')).toBe(true)
  })

  it('shows an error for non-absolute paths after interaction', async () => {
    mountDialog()
    await nextTick()
    const pathInput = document.querySelector('[data-testid="agent-knowledge-path"]') as HTMLInputElement
    pathInput.value = 'relative/path.md'
    pathInput.dispatchEvent(new Event('input'))
    pathInput.dispatchEvent(new Event('blur'))
    await nextTick()
    const error = document.querySelector('[data-testid="agent-knowledge-path-error"]') as HTMLElement
    expect(error).toBeTruthy()
    expect(error.textContent).toContain('absolute')
  })

  it('emits create with (file_path, label) when submit clicked with valid input', async () => {
    const wrapper = mountDialog()
    await nextTick()
    const pathInput = document.querySelector('[data-testid="agent-knowledge-path"]') as HTMLInputElement
    pathInput.value = '/home/me/docs/spec.md'
    pathInput.dispatchEvent(new Event('input'))
    await nextTick()
    const labelInput = document.querySelector('[data-testid="agent-knowledge-label"]') as HTMLInputElement
    labelInput.value = 'Project spec'
    labelInput.dispatchEvent(new Event('input'))
    await nextTick()
    const submit = document.querySelector('[data-testid="agent-knowledge-submit"]') as HTMLButtonElement
    submit.click()
    await nextTick()
    const events = wrapper.emitted('create')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual(['/home/me/docs/spec.md', 'Project spec'])
  })
})
