/**
 * Behavioural tests for the ShowPreview.vue card.
 *
 * ShowPreview is the per-message card rendered in the chat bubble
 * for each `show_preview` agent tool message. It always renders
 * inline: header (title, content_type, content_length, ✓/✗) PLUS
 * the rich content via <PreviewContentRenderer>. HTML previews
 * offer an "Open in new tab" action for full-width viewing.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import ShowPreview from '../components/tool_outputs/ShowPreview.vue'

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

  return {
    id: opts.id,
    content: innerData,
    parameters: JSON.stringify(params),
    messageId: opts.id,
  }
}

describe('ShowPreview card (inline-only)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders the header + inline markdown body', () => {
    const msg = makeShowPreviewMessage({
      id: 'msg-inline-1',
      contentType: 'markdown',
      content: '# Inline Title',
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

  it('renders inline html content in a sandboxed iframe with new-tab action', () => {
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
    expect(
      wrapper.find('[data-testid="preview-open-new-tab-button"]').exists(),
    ).toBe(true)
  })

  it('renders the error body when the tool failed', () => {
    const msg = makeShowPreviewMessage({
      id: 'msg-err-1',
      contentType: 'markdown',
      content: '# nope',
      isSuccess: false,
    })
    const wrapper = mount(ShowPreview, {
      props: {
        content: msg.content,
        parameters: msg.parameters,
        messageId: msg.id,
      },
    })
    expect(wrapper.html()).toContain('✗')
    expect(wrapper.html()).toContain('something went wrong')
    expect(
      wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
    ).toBe(false)
  })

  it('does not emit any open event (no side panel)', async () => {
    const msg = makeShowPreviewMessage({
      id: 'msg-noopen-1',
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
    await wrapper.trigger('click')
    expect(wrapper.emitted()).not.toHaveProperty('open')
  })
})
