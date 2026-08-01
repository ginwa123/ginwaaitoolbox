/**
 * Behavioural tests for the ShowPreview.vue card.
 *
 * ShowPreview is the per-message card rendered in the chat bubble
 * for each `show_preview` agent tool message. It has two display
 * modes controlled by the global `usePreviewDisplayMode` composable:
 *
 *   - 'side' (default, current behaviour):
 *       Renders just the header (title, content_type, content_length,
 *       ✓/✗). Click → emits `open` with the message id, parent
 *       focuses the matching preview tab in the side panel.
 *
 *   - 'inline' (new, 2026-08-06):
 *       Renders the header PLUS the rich content via
 *       <PreviewContentRenderer>. Click does NOT emit `open` —
 *       there's nothing to navigate to.
 *
 * These tests lock in both modes. Mounting uses the same `<tool>`
 * envelope shape the backend produces (matching
 * chatViewShowPreviewBubble.spec.ts:80-99).
 *
 * Plan: docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import ShowPreview from '../components/tool_outputs/ShowPreview.vue'
import { PREVIEW_DISPLAY_MODE_STORAGE_KEY } from '../composables/usePreviewDisplayMode'

function makeLocalStorageStub(): Storage {
  const store: Record<string, string> = {}
  return {
    getItem: (k: string) => (k in store ? store[k] : null),
    setItem: (k: string, v: string) => { store[k] = String(v) },
    removeItem: (k: string) => { delete store[k] },
    clear: () => { for (const k in store) delete store[k] },
    key: () => null,
    length: 0,
  } as Storage
}

// Build the `<tool>...</tool>` envelope the backend stores in
// `llm_history.response_content`. Mirrors makeShowPreviewMessage
// in chatViewShowPreviewBubble.spec.ts.
function makeShowPreviewMessage(opts: {
  id: string
  contentType: 'markdown' | 'text' | 'code' | 'image' | 'html'
  content: string
  title?: string
  language?: string
  caption?: string
  isSuccess?: boolean
}) {
  const params: Record<string, string> = {
    content_type: opts.contentType,
    content: opts.content,
  }
  if (opts.title) params.title = opts.title
  if (opts.language) params.language = opts.language
  if (opts.caption) params.caption = opts.caption

  const isSuccess = opts.isSuccess ?? true
  const innerData = isSuccess
    ? `<show_preview><status>shown</status><preview_id>pv_${opts.id}</preview_id><content_type>${opts.contentType}</content_type><content_length>${opts.content.length}</content_length></show_preview>`
    : `<show_preview><error>something went wrong</error></show_preview>`

  const envelope = `<tool><name>show_preview</name><parameters>${JSON.stringify(params)}</parameters><success>${isSuccess ? 'true' : 'false'}</success><data>${innerData}</data></tool>`
  return {
    id: opts.id,
    content: envelope,
    parameters: JSON.stringify(params),
    messageId: opts.id,
  }
}

describe('ShowPreview card', () => {
  beforeEach(() => {
    // Fresh localStorage stub so mode persistence tests are isolated.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    setActivePinia(createPinia())
  })

  describe('side mode (default)', () => {
    it('renders the header with title + content_type badge', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-1',
        contentType: 'markdown',
        content: '# Plan',
        title: 'Migration Plan',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      expect(wrapper.html()).toContain('show_preview')
      expect(wrapper.html()).toContain('Migration Plan')
      expect(wrapper.html()).toContain('markdown')
      expect(wrapper.html()).toContain('✓')
    })

    it('does NOT render the inline content body in side mode', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-2',
        contentType: 'markdown',
        content: '# Plan',
        title: 'Plan',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      // No inline content body — only the header is rendered.
      expect(
        wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
      ).toBe(false)
    })

    it('clicking the card in side mode emits "open" with the message id', async () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-3',
        contentType: 'markdown',
        content: '# x',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const card = wrapper.find(`[data-testid="show-preview-card-msg-side-3"]`)
      expect(card.exists()).toBe(true)
      await card.trigger('click')
      expect(wrapper.emitted('open')).toBeTruthy()
      expect(wrapper.emitted('open')?.[0]).toEqual(['msg-side-3'])
    })

    it('renders as a clickable role="button" with tabindex="0" in side mode', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-4',
        contentType: 'markdown',
        content: '# x',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const card = wrapper.find(`[data-testid="show-preview-card-msg-side-4"]`)
      expect(card.attributes('role')).toBe('button')
      expect(card.attributes('tabindex')).toBe('0')
    })
  })

  describe('inline mode', () => {
    beforeEach(() => {
      // Set the mode BEFORE mounting so the composable reads it on init.
      localStorage.setItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY, 'inline')
    })

    it('renders the inline content body with the markdown via <h1>', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-1',
        contentType: 'markdown',
        content: '# Inline Title',
        title: 'Plan',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      expect(
        wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
      ).toBe(true)
      expect(wrapper.html()).toContain('<h1')
      expect(wrapper.html()).toContain('Inline Title')
    })

    it('renders inline code content with the language class', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-2',
        contentType: 'code',
        content: 'fn main() void {}',
        language: 'zig',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      expect(wrapper.html()).toContain('language-zig')
    })

    it('renders inline image content as <img>', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-3',
        contentType: 'image',
        content: 'data:image/png;base64,iVBORw0KGgo=',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const img = wrapper.find('img')
      expect(img.exists()).toBe(true)
      expect(img.attributes('src')).toBe('data:image/png;base64,iVBORw0KGgo=')
    })

    it('renders inline html content in a sandboxed iframe', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-4',
        contentType: 'html',
        content: '<h1>Hi</h1>',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const iframe = wrapper.find('iframe')
      expect(iframe.exists()).toBe(true)
      expect(iframe.attributes('sandbox')).toBe('allow-scripts')
    })

    it('clicking the card in inline mode does NOT emit "open"', async () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-5',
        contentType: 'markdown',
        content: '# Inline',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const card = wrapper.find(`[data-testid="show-preview-card-msg-inline-5"]`)
      expect(card.exists()).toBe(true)
      await card.trigger('click')
      // No navigate-to-side-panel action — the content is already visible.
      expect(wrapper.emitted('open')).toBeFalsy()
    })

    it('inline mode does NOT add role="button" or tabindex (not a click target)', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-6',
        contentType: 'markdown',
        content: '# Inline',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const card = wrapper.find(`[data-testid="show-preview-card-msg-inline-6"]`)
      expect(card.attributes('role')).toBeUndefined()
      expect(card.attributes('tabindex')).toBeUndefined()
    })

    it('flipping mode to inline AFTER mount renders the content (reactive)', async () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-7',
        contentType: 'markdown',
        content: '# Reactive',
      })
      // Start in side mode by clearing localStorage for this test.
      // (The describe-block beforeEach sets 'inline' — we override.)
      localStorage.removeItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY)

      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      // Started in side mode — no inline content yet.
      expect(
        wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
      ).toBe(false)

      // Flip to inline via the toggle UI (the Side / Inline
      // buttons call `setMode` internally). We call the same
      // composable to verify reactivity propagates without a
      // remount.
      const { usePreviewDisplayMode } = await import(
        '../composables/usePreviewDisplayMode'
      )
      usePreviewDisplayMode().setMode('inline')
      await nextTick()

      expect(
        wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
      ).toBe(true)
    })

    it('error responses do NOT render inline content (only the header + error body)', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-inline-err',
        contentType: 'markdown',
        content: '# x',
        isSuccess: false,
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      // Even in inline mode, an error card doesn't render the
      // rich content body — the error message itself is shown
      // in the dedicated error body section.
      expect(
        wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
      ).toBe(false)
      expect(wrapper.html()).toContain('something went wrong')
    })
  })
})