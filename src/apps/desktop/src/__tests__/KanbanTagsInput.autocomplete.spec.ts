/**
 * KanbanTagsInput — autocomplete dropdown behavioural tests.
 *
 * Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
 * (Task 2.5 — RED step, Task 2.6 — GREEN step)
 *
 * Covers:
 *   1. Dropdown visibility (empty / non-empty suggestions)
 *   2. Filtering by case-insensitive prefix
 *   3. Hiding suggestions already on the task
 *   4. Click-to-commit
 *   5. Keyboard navigation (ArrowDown + Enter)
 *   6. Escape handling (close without commit)
 *   7. Blur with delayed close
 *   8. Enter without highlight still commits the typed draft
 *   9. Scroll sentinel rendering (gated on hasMore)
 *   10. "Loading more…" indicator (gated on loadingMore)
 *   11. IntersectionObserver fires onLoadMore when sentinel visible
 *   12. rootMargin config check
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import KanbanTagsInput from '../components/kanban/KanbanTagsInput.vue'

describe('KanbanTagsInput — autocomplete dropdown', () => {
  beforeEach(() => {
    // No global setup; the component is fully self-contained.
  })

  it('does not show the dropdown when there are no suggestions', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: [] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('shows the dropdown when focused and suggestions are provided', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
  })

  it('filters suggestions by case-insensitive prefix', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent', 'bugfix', 'frontend'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'BUG'
    await input.trigger('input')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bugfix"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(false)
  })

  it('hides suggestions that are already chips on the task', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['bug'], suggestions: ['bug', 'urgent', 'frontend'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestion-urgent"]').exists()).toBe(true)
  })

  it('clicking a suggestion commits it as a tag and closes the dropdown', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    await wrapper.find('[data-testid="kanban-tags-input-suggestion-bug"]').trigger('mousedown')
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug']])
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('ArrowDown + Enter commits the highlighted suggestion', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug', 'urgent'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    await input.trigger('focus')
    await nextTick()
    await input.trigger('keydown', { key: 'ArrowDown' })
    await input.trigger('keydown', { key: 'Enter' })
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['bug']])
  })

  it('Escape closes the dropdown but does NOT commit a draft', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'partial'
    await input.trigger('input')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    await input.trigger('keydown', { key: 'Escape' })
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })

  it('hides the dropdown after blur (delayed close so clicks can fire)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find('[data-testid="kanban-tags-input-field"]')
    await input.trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(true)
    await input.trigger('blur')
    await new Promise((r) => setTimeout(r, 200))
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions"]').exists()).toBe(false)
  })

  it('Enter without a highlight still commits the typed draft (existing behavior)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [], suggestions: ['bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'custom-tag'
    await input.trigger('input')
    await input.trigger('focus')
    await input.trigger('keydown', { key: 'Enter' })
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['custom-tag']])
  })

  // ─── Pagination tests ──────────────────────────────────────────────────

  it('renders the scroll sentinel when hasMore is true', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: true,
        loadingMore: false,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-sentinel"]').exists()).toBe(true)
  })

  it('does NOT render the scroll sentinel when hasMore is false', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: false,
        loadingMore: false,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-sentinel"]').exists()).toBe(false)
  })

  it('renders the "Loading more…" indicator when loadingMore is true', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: {
        modelValue: [],
        suggestions: ['bug'],
        hasMore: true,
        loadingMore: true,
      },
    })
    await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-suggestions-loading"]').exists()).toBe(true)
  })

  it('IntersectionObserver fires onLoadMore when the scroll sentinel is visible', async () => {
    // jsdom doesn't trigger IntersectionObserver by default,
    // so we stub the constructor to call the callback with
    // isIntersecting=true synchronously.
    const originalIO = globalThis.IntersectionObserver
    let capturedCb: IntersectionObserverCallback | null = null
    let capturedOpts: IntersectionObserverInit | null = null
    ;(globalThis as any).IntersectionObserver = class MockIntersectionObserver {
      constructor(cb: IntersectionObserverCallback, opts?: IntersectionObserverInit) {
        capturedCb = cb
        capturedOpts = opts ?? null
      }
      observe() {}
      disconnect() {}
    }

    const onLoadMore = vi.fn()
    try {
      const wrapper = mount(KanbanTagsInput, {
        props: {
          modelValue: [],
          suggestions: ['bug', 'urgent'],
          hasMore: true,
          loadingMore: false,
          onLoadMore,
        },
      })
      await wrapper.find('[data-testid="kanban-tags-input-field"]').trigger('focus')
      await nextTick()
      // Fire the observer callback as if the sentinel is visible.
      capturedCb?.(
        [{ isIntersecting: true } as IntersectionObserverEntry],
        null as any,
      )
      expect(onLoadMore).toHaveBeenCalledTimes(1)
      // Verify the rootMargin config (100px preload).
      expect(capturedOpts?.rootMargin).toBe('0px 0px 100px 0px')
    } finally {
      ;(globalThis as any).IntersectionObserver = originalIO
    }
  })
})
