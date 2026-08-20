// Behavioural tests for AgentKnowledgeDialog.

import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AgentKnowledgeDialog from './AgentKnowledgeDialog.vue'

// Stub the FilePickerDialog — same pattern as AddAgentDialog.spec.ts.
// The real FilePickerDialog uses useRecentFoldersStore which requires
// an active Pinia; stubbing it isolates this test from that.
vi.mock('../FilePickerDialog.vue', () => ({
  default: {
    name: 'FilePickerDialog',
    props: ['modelValue', 'mode', 'loadItems', 'keyFor', 'pathFor', 'isExpandable', 'labelFor', 'title'],
    emits: ['update:modelValue', 'select'],
    template: `
      <div v-if="modelValue" data-testid="file-picker-dialog">
        <h2 data-testid="file-picker-title">{{ title }}</h2>
        <button data-testid="file-picker-select" @click="$emit('select', '/tmp/picked.md')">
          Pick /tmp/picked.md
        </button>
        <button data-testid="file-picker-cancel" @click="$emit('update:modelValue', false)">
          Cancel
        </button>
      </div>
    `,
  },
}))

function mountDialog(props: Record<string, unknown> = {}) {
  // The dialog uses <Teleport to="body">, so we attach to document.body
  // and search via document.querySelector. Same pattern as
  // AddAgentDialog.spec.ts.
  document.body.innerHTML = ''
  return mount(AgentKnowledgeDialog, {
    attachTo: document.body,
    props: { show: true, ...props },
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

  it('shows the "Adding…" label and disables submit when busy=true', async () => {
    mountDialog({ busy: true })
    await nextTick()
    const submit = document.querySelector('[data-testid="agent-knowledge-submit"]') as HTMLButtonElement
    expect(submit.hasAttribute('disabled')).toBe(true)
    expect(submit.textContent).toContain('Adding')
  })

  it('renders the error banner when error prop is set', async () => {
    mountDialog({ error: 'Server rejected the file path' })
    await nextTick()
    const errBanner = document.querySelector('[data-testid="agent-knowledge-error"]') as HTMLElement
    expect(errBanner).toBeTruthy()
    expect(errBanner.textContent).toContain('Server rejected the file path')
  })

  it('renders a Browse button that opens the file picker', async () => {
    mountDialog()
    await nextTick()
    const browse = document.querySelector('[data-testid="agent-knowledge-browse"]') as HTMLButtonElement
    expect(browse).toBeTruthy()
  })

  it('disables Cancel + Browse when busy=true (avoid closing mid-submit)', async () => {
    mountDialog({ busy: true })
    await nextTick()
    const cancel = document.querySelector('[data-testid="agent-knowledge-cancel"]') as HTMLButtonElement
    const browse = document.querySelector('[data-testid="agent-knowledge-browse"]') as HTMLButtonElement
    expect(cancel.hasAttribute('disabled')).toBe(true)
    expect(browse.hasAttribute('disabled')).toBe(true)
  })
})
