import { beforeEach, describe, expect, it } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useWorkspacesStore } from '../stores/workspaces'

describe('workspacesStore active design page', () => {
  beforeEach(() => { setActivePinia(createPinia()) })
  it('activeDesignPageId defaults to empty string', () => {
    const store = useWorkspacesStore()
    expect(store.activeDesignPageId).toBe('')
  })
  it('setActiveDesignPage updates the ref', () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_abc')
    expect(store.activeDesignPageId).toBe('page_abc')
  })
  it('setActiveDesignPage with empty string clears the ref', () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_abc')
    store.setActiveDesignPage('')
    expect(store.activeDesignPageId).toBe('')
  })
})
