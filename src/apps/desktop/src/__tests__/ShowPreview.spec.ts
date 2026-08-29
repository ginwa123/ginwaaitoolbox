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

// Build the inner data envelope (no `<tool>` wrapper) + parameters
// JSON-string. Mirrors what ChatView.vue:1069-1080 passes to the
// component in production:
//   - content       = innerToolData(msg)       = unwrapped.data
//   - parameters    = getParametersForMessage  = unwrapped.parameters
// The previous fixture in this spec used a `<tool>`-wrapped envelope
// for `content`, which masked a real production bug (the bug was
// that the inline mode tried to unwrap `content` looking for the
// `<tool>` wrapper, but `content` only carries the INNER envelope).
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
  // Inner data — what's inside <data>...</data> in the full <tool>
  // envelope. ChatView unwraps the <tool> and passes this as content.
  const innerData = isSuccess
    ? `<show_preview><status>shown</status><preview_id>pv_${opts.id}</preview_id><content_type>${opts.contentType}</content_type><content_length>${opts.content.length}</content_length></show_preview>`
    : `<show_preview><error>something went wrong</error></show_preview>`

  return {
    id: opts.id,
    // content = inner data envelope (NO <tool> wrapper)
    content: innerData,
    // parameters = JSON-string of the show_preview tool-call args
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

  describe('inline mode (opt-in alternative — user toggled via PreviewSidePanel header)', () => {
    // 2026-08-29: the DEFAULT flipped back to 'side' (was incorrectly
    // 'inline' after the 2026-08-06 spec merged). These tests now opt INTO
    // inline via localStorage to exercise the inline renderer. Mirror
    // image of the side-mode describe block below. Plan:
    // docs/superpowers/plans/2026-08-29-show-preview-inline-default-and-ux.md
    beforeEach(() => {
      localStorage.setItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY, 'inline')
    })

    it('renders the header + inline content body with the markdown via <h1>', () => {
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
      // Header (always visible)
      expect(wrapper.html()).toContain('show_preview')
      expect(wrapper.html()).toContain('Migration Plan')
      expect(wrapper.html()).toContain('markdown')
      expect(wrapper.html()).toContain('✓')
      // Inline content body
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

    it('inline mode does NOT emit "open" on card click (content already visible)', async () => {
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

  describe('side mode (default — matches 2026-08-06 spec)', () => {
    // 2026-08-29: 'side' is now the DEFAULT again. The beforeEach pins
    // localStorage explicitly so the test is independent of any
    // previous-test localStorage residue.
    beforeEach(() => {
      localStorage.setItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY, 'side')
    })

    it('renders only the header in side mode (no inline content body)', () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-1',
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
      expect(wrapper.html()).toContain('show_preview')
      expect(wrapper.html()).toContain('Plan')
      // No inline content body — the user has opted to see previews in the side panel.
      expect(
        wrapper.find('[data-testid="show-preview-inline-content"]').exists(),
      ).toBe(false)
    })

    it('clicking the card in side mode emits "open" with the message id (parent focuses side panel)', async () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-2',
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
      const card = wrapper.find(`[data-testid="show-preview-card-msg-side-2"]`)
      expect(card.exists()).toBe(true)
      await card.trigger('click')
      expect(wrapper.emitted('open')).toBeTruthy()
      expect(wrapper.emitted('open')?.[0]).toEqual(['msg-side-2'])
    })

    it('renders as a clickable role="button" with tabindex="0" in side mode', () => {
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
      expect(card.attributes('role')).toBe('button')
      expect(card.attributes('tabindex')).toBe('0')
    })

    it('flipping mode to inline AFTER mount renders the content (reactive)', async () => {
      const msg = makeShowPreviewMessage({
        id: 'msg-side-4',
        contentType: 'markdown',
        content: '# Reactive',
      })
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
  })

  // ─── Production-shape parameters (XML, not JSON) ──────────────────
  //
  // Background: ChatView.vue passes `parameters` as the result of
  // `tryUnwrapToolOutput(msg.content)?.parameters`, which is the
  // XML-unescaped inner content of the `<parameters>...</parameters>`
  // tag. Since the backend's `jsonArgsToXml` (tools_wrap_output.zig)
  // converts the JSON args into `<content_type>html</content_type>
  // <content>...</content>` form (after the 2026 PR #55 double-wrap
  // fix), the `parameters` prop in PRODUCTION is XML, not raw JSON.
  //
  // The earlier tests in this file use `JSON.stringify(params)` for
  // convenience, which doesn't match production. They test the
  // "legacy raw-JSON" path, which `JSON.parse(props.parameters)`
  // handles correctly. The tests below use the actual production
  // shape (XML) and currently FAIL because `ShowPreview.vue` only
  // does `JSON.parse(props.parameters)` — XML throws SyntaxError,
  // falls through to `{}`, and the iframe renders blank.
  //
  // See commit history (2026-08-06): tools_wrap_output.zig was
  // fixed to stop double-wrapping the params; the side panel was
  // updated then to read XML via `findTag`; ShowPreview.vue was NOT
  // updated, so chat-bubble HTML previews render blank while the
  // same preview in the side panel renders correctly. THE BUG.
  describe('production-shape parameters (XML from jsonArgsToXml)', () => {
    // 2026-08-29: opt into inline rendering (was the default before
    // the show_preview default flip).
    beforeEach(() => {
      localStorage.setItem(PREVIEW_DISPLAY_MODE_STORAGE_KEY, 'inline')
    })
    /**
     * Build the production-shape parameters string. This mirrors what
     * `tryUnwrapToolOutput(msg.content)?.parameters` returns AFTER one
     * layer of XML-unescape has been applied to the backend's escaped
     * form. Concretely:
     *
     *   Backend produces (jsonArgsToXml escapes each JSON value once):
     *     <parameters><content_type>html</content_type>
     *       <content>&lt;p&gt;A &amp; B &lt; C&lt;/p&gt;</content></parameters>
     *
     *   tryUnwrapToolOutput unescapes the entire parameters string
     *   once → result has raw text inside each tag:
     *     <content_type>html</content_type>
     *       <content><p>A & B < C</p></content>
     *
     * The fixture below matches the SECOND form (raw text — no inner
     * escape), which is what reaches `ShowPreview.vue::props.parameters`
     * in production. For test inputs that don't contain `</content>`
     * the raw insertion is safe (findXmlTag uses simple indexOf on
     * the literal `<content>` / `</content>` delimiters).
     */
    function buildXmlParameters(input: {
      content_type: string
      content: string
      title?: string
      language?: string
      caption?: string
    }): string {
      let xml = `<content_type>${input.content_type}</content_type>`
      xml += `<content>${input.content}</content>`
      if (input.title) xml += `<title>${input.title}</title>`
      if (input.language) xml += `<language>${input.language}</language>`
      if (input.caption) xml += `<caption>${input.caption}</caption>`
      return xml
    }

    function makeXmlMessage(opts: {
      id: string
      contentType: 'markdown' | 'text' | 'code' | 'image' | 'html'
      content: string
      title?: string
      language?: string
    }) {
      // The inner data envelope is the same shape regardless of params format.
      const innerData = [
        '<show_preview>',
        '<status>shown</status>',
        '<preview_id>pv_xml_1</preview_id>',
        `<content_type>${opts.contentType}</content_type>`,
        `<content_length>${opts.content.length}</content_length>`,
        '</show_preview>',
      ].join('')
      return {
        id: opts.id,
        content: innerData,
        parameters: buildXmlParameters({
          content_type: opts.contentType,
          content: opts.content,
          title: opts.title,
          language: opts.language,
        }),
        messageId: opts.id,
      }
    }

    it('renders the html content into the iframe when parameters are XML (production shape)', () => {
      const msg = makeXmlMessage({
        id: 'xml-html-1',
        contentType: 'html',
        content: '<h1>Hi from XML params</h1>',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
      expect(iframe.exists()).toBe(true)
      const srcdoc = iframe.attributes('srcdoc') ?? ''
      // The raw HTML MUST be present in the iframe's srcdoc. If
      // `JSON.parse(props.parameters)` swallowed the XML silently
      // (the pre-fix bug), the iframe renders only the <style> reset
      // and the user HTML is missing.
      expect(srcdoc).toContain('<h1>Hi from XML params</h1>')
    })

    it('renders the markdown content body when parameters are XML', () => {
      const msg = makeXmlMessage({
        id: 'xml-md-1',
        contentType: 'markdown',
        content: '# XML Title\n\nBody text.',
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
      // The marked.parse output should contain the heading.
      expect(wrapper.html()).toContain('XML Title')
      expect(wrapper.html()).toContain('Body text.')
    })

    it('renders the code language class when parameters are XML', () => {
      const msg = makeXmlMessage({
        id: 'xml-code-1',
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

    it('renders the image src when parameters are XML', () => {
      const msg = makeXmlMessage({
        id: 'xml-img-1',
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

    it('renders the title (from XML params) next to the content_type in the header', () => {
      const msg = makeXmlMessage({
        id: 'xml-title-1',
        contentType: 'markdown',
        content: '# Body',
        title: 'My Plan',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      // The header label prefers the parameter title.
      expect(wrapper.html()).toContain('My Plan')
      expect(wrapper.html()).toContain('markdown')
    })

    it('the raw user HTML is passed through into the iframe srcdoc (post-unescape state)', () => {
      // After tryUnwrapToolOutput's one layer of XML-unescape, the
      // parameters string has the raw user HTML inside <content>...</content>.
      // ShowPreview's extractor (extractPreviewArgs) must surface the
      // raw HTML so the iframe renders it as HTML (not as escaped text).
      const msg = makeXmlMessage({
        id: 'xml-html-2',
        contentType: 'html',
        content: '<p>A & B < C</p>',
      })
      const wrapper = mount(ShowPreview, {
        props: {
          content: msg.content,
          parameters: msg.parameters,
          messageId: msg.id,
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
      const srcdoc = iframe.attributes('srcdoc') ?? ''
      // The raw HTML must be present in the decoded attribute value.
      // If extractPreviewArgs swallowed the content (or kept it
      // double-escaped), the iframe would render the literal text
      // "&lt;p&gt;..." instead of the actual <p>...</p> element.
      expect(srcdoc).toContain('<p>A & B < C</p>')
    })
  })
})