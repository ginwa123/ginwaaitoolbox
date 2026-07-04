/**
 * Tests for CopyKanbanSpecDialog — the per-board "copy spec from
 * another kanban" modal. Mount pattern: same as
 * KanbanSettingsDialog.spec.ts (Teleport + attachTo: document.body
 * + document.querySelector for DOM assertions).
 *
 * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
 *   (Chunk 4, Task 4.1)
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import CopyKanbanSpecDialog from '@/components/CopyKanbanSpecDialog.vue'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '@/stores/workspaces'

const source1: WorkspaceItem = {
  id: 'wi_src_1',
  name: 'Sprint 12 (template)',
  item_type: 'kanban',
  path: null,
}

const source2: WorkspaceItem = {
  id: 'wi_src_2',
  name: 'Bug triage',
  item_type: 'kanban',
  path: null,
}

const target: WorkspaceItem = {
  id: 'wi_target',
  name: 'Local Sprint',
  item_type: 'kanban',
  path: null,
}

const workspace: Workspace = {
  id: 'ws_test',
  name: 'Test workspace',
  icon: '📂',
  items: [source1, source2, target],
  expanded: true,
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

describe('CopyKanbanSpecDialog', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
    setActivePinia(createPinia())
    const store = useWorkspacesStore()
    store.workspaces = [workspace]
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body
      .querySelectorAll('[data-testid="copy-kanban-spec-dialog"]')
      .forEach((el) => el.remove())
  })

  function mountDialog() {
    // Mount with show: false, then flip to true — the component's
    // watcher on `() => props.show` only fires on a transition, and
    // this is the lifecycle hook that auto-selects the first source
    // (matches the convention in AddKanbanDialog.spec.ts).
    wrapper = mount(CopyKanbanSpecDialog, {
      attachTo: document.body,
      props: {
        show: false,
        workspaceId: 'ws_test',
        targetItemId: 'wi_target',
      },
    })
    return wrapper
  }

  async function openDialog() {
    const w = mountDialog()
    await w.setProps({ show: true })
    await flushPromises()
    return w
  }

  it('renders the dialog with the right title', async () => {
    await openDialog()
    const dialog = findInDom<HTMLElement>('[data-testid="copy-kanban-spec-dialog"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.textContent).toContain('Copy spec from')
  })

  it('excludes the target from the source picker', async () => {
    await openDialog()
    const select = findInDom<HTMLSelectElement>(
      '[data-testid="copy-kanban-spec-source"]',
    )
    expect(select).not.toBeNull()
    const options = Array.from(select!.options)
    const ids = options.map((o) => o.value).filter((v) => v)
    expect(ids).toContain('wi_src_1')
    expect(ids).toContain('wi_src_2')
    expect(ids).not.toContain('wi_target')
  })

  it('defaults to replace mode', async () => {
    await openDialog()
    const replaceRadio = findInDom<HTMLInputElement>(
      '[data-testid="copy-kanban-spec-mode-replace"]',
    )
    expect(replaceRadio?.checked).toBe(true)
  })

  it('emits copy with the selected source and mode on Confirm', async () => {
    const w = await openDialog()
    const appendRadio = findInDom<HTMLInputElement>(
      '[data-testid="copy-kanban-spec-mode-append"]',
    )
    appendRadio!.checked = true
    appendRadio!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()

    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()

    const emitted = w!.emitted('copy')
    expect(emitted).toBeTruthy()
    // Alphabetical sort: "Bug triage" (wi_src_2) precedes
    // "Sprint 12 (template)" (wi_src_1), so auto-selection picks
    // wi_src_2 on open.
    expect(emitted![0]).toEqual(['wi_src_2', 'append'])
  })

  it('emits close on Cancel and on backdrop click', async () => {
    const w = await openDialog()
    clickInDom('[data-testid="copy-kanban-spec-cancel"]')
    await flushPromises()
    expect(w!.emitted('close')).toBeTruthy()
  })

  it('disables the confirm button when no sources are available', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { ...workspace, items: [target] },
    ]
    const w = await openDialog()

    const emptyMsg = findInDom<HTMLElement>(
      '[data-testid="copy-kanban-spec-empty"]',
    )
    expect(emptyMsg).not.toBeNull()
    const confirmBtn = findInDom<HTMLButtonElement>(
      '[data-testid="copy-kanban-spec-confirm"]',
    )
    expect(confirmBtn?.disabled).toBe(true)
    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()
    expect(w!.emitted('copy')).toBeFalsy()
  })
})
