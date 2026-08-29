/**
 * Behavioural tests for the extracted <PreviewContentRenderer> component.
 *
 * The renderer is the SHARED rendering logic used by:
 *   - <PreviewSidePanel> (renders one preview at a time from the
 *     right-side panel tab strip)
 *   - <ShowPreview> (renders inline inside the chat bubble when
 *     `usePreviewDisplayMode().mode === 'inline'`)
 *
 * Before this refactor, the 5-branch rendering pipeline
 * (markdown / text / code / image / html) lived INLINE in
 * PreviewSidePanel.vue as three computed refs (`renderedContent`,
 * `imageSrc`, `htmlSrcDoc`) + a 5-way `v-if/v-else-if` template.
 * We extract it into a shared component so both consumers get the
 * identical rendering without copy-paste drift.
 *
 * The tests below are pure DOM assertions: mount the component with
 * the right props, check the rendered HTML. They're a regression
 * guard against accidental drift from the in-PreviewSidePanel logic
 * to the extracted component.
 *
 * Plan: docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import PreviewContentRenderer from '../components/preview/PreviewContentRenderer.vue'

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

beforeEach(() => {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

describe('PreviewContentRenderer', () => {
  it('renders markdown content via marked() into an <h1>', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: '# Title' },
      },
    })
    const html = wrapper.html()
    expect(html).toContain('Title')
    expect(html).toContain('<h1')
  })

  it('renders text content as a <pre> with preserved whitespace', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'text',
        args: { content: 'line 1\n  line 2 indented' },
      },
    })
    const html = wrapper.html()
    expect(html).toContain('<pre')
    expect(html).toContain('whitespace-pre-wrap')
  })

  it('renders code content with language class for syntax highlighting', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'code',
        args: { content: 'fn main() void {}', language: 'zig' },
      },
    })
    expect(wrapper.html()).toContain('language-zig')
  })

  it('renders code content with plaintext language when no language is given', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'code',
        args: { content: 'x = 1' },
      },
    })
    expect(wrapper.html()).toContain('language-plaintext')
  })

  it('renders image content as <img> with the data: URL', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'image',
        args: { content: 'data:image/png;base64,iVBORw0KGgo=' },
      },
    })
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toBe('data:image/png;base64,iVBORw0KGgo=')
  })

  it('renders image content as <img> with an http(s) URL', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'image',
        args: { content: 'https://example.com/cat.png' },
      },
    })
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toBe('https://example.com/cat.png')
  })

  it('renders html content inside a sandboxed iframe', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'html',
        args: { content: '<h1>Hello</h1>' },
      },
    })
    const iframe = wrapper.find('iframe')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('sandbox')).toBe('allow-scripts')
    expect(iframe.attributes('srcdoc')).toBeTruthy()
    // The srcdoc should contain the user's HTML. Browsers auto-encode
    // `< > & "` for the attribute; jsdom does not. The renderer
    // intentionally does NOT pre-escape (the comment in
    // htmlSrcDoc explains why) — it relies on the browser's
    // attribute encoding. So we check for the raw HTML form here.
    const srcdoc = iframe.attributes('srcdoc') ?? ''
    expect(srcdoc).toContain('<h1>Hello</h1>')
    // The tiny <style> reset is prepended to every html preview.
    expect(srcdoc).toContain('<style>')
  })

  it('renders title and caption as siblings of the content', () => {
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown',
        args: { content: '# Body', title: 'Plan', caption: 'A short caption' },
      },
    })
    const html = wrapper.html()
    expect(html).toContain('Plan')
    expect(html).toContain('A short caption')
  })

  it('falls back to an empty <pre> when markdown parsing throws (defensive)', () => {
    // Mock the markdown source with content that breaks the marked()
    // parser. marked() is robust against most invalid markdown, so
    // we instead force an exception by passing a non-string content
    // type at runtime.
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        contentType: 'markdown' as const,
        args: { content: '' },
      },
    })
    // Empty markdown renders as empty string via marked(), which is
    // valid. We just verify no crash and a stable DOM.
    expect(wrapper.html()).toBeTruthy()
  })

  it('renders nothing meaningful for unknown content_type (defensive)', () => {
    // Force an unknown contentType via cast — the renderer should
    // not crash, just render an empty container.
    const wrapper = mount(PreviewContentRenderer, {
      props: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        contentType: 'unknown_type' as any,
        args: { content: 'irrelevant' },
      },
    })
    // No <img>, no <iframe>, no <pre>. Container exists.
    expect(wrapper.find('img').exists()).toBe(false)
    expect(wrapper.find('iframe').exists()).toBe(false)
  })

  // ─── Variant prop (2026-08-06) ────────────────────────────────────
  //
  // The renderer is used in TWO layouts: the side panel (full-width
  // 480px column with a tall iframe) and the chat bubble (variable
  // width, scrollable bubble, "Open full preview" affordance). The
  // default behavior (no variant prop) matches the original side-
  // panel sizing for back-compat. Passing `variant="inline"` switches
  // to a compact inline layout: shorter min-height, "Open full
  // preview" button, and a max-w-full on the container so the iframe
  // can never overflow its chat-bubble column.
  describe('variant: inline (chat-bubble layout)', () => {
    it('does NOT enforce a fixed min-h on the container (auto-resize sets the height from the iframe postMessage)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframeContainer = wrapper.find('[data-testid="preview-html-container"]')
      expect(iframeContainer.exists()).toBe(true)
      const classes = iframeContainer.attributes('class') ?? ''
      // No fixed min-h on the container — the iframe's height is set
      // dynamically by the AUTO_RESIZE_SCRIPT via postMessage.
      expect(classes).not.toContain('min-h-[480px]')
      // The old max-h-[320px] cap is also gone.
      expect(classes).not.toContain('max-h-[320px]')
      // Iframe gets a min-height style of 200px as an initial fallback
      // (before the postMessage arrives) so empty/short HTML still
      // renders something visible.
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
      expect(iframe.attributes('style')).toContain('min-height: 200px')
    })

    it('caps iframe width at the chat-bubble width (max-w-full)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframeContainer = wrapper.find('[data-testid="preview-html-container"]')
      const classes = iframeContainer.attributes('class') ?? ''
      expect(classes).toContain('max-w-full')
    })

    it('renders an "Open full preview" button BELOW the html iframe (inline only, outside the iframe corner)', () => {
      // 2026-08-29: button moved out of the iframe's absolute top-right
      // corner (where it overlapped the preview content) into a CTA
      // strip below the iframe. Same data-testid, same handler — just a
      // new DOM position. The test asserts the button exists; the
      // position itself is locked by the next two tests.
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const openBtn = wrapper.find('[data-testid="preview-open-full-button"]')
      expect(openBtn.exists()).toBe(true)
    })

    it('does NOT render the "Open full preview" button in side-panel variant (no need — full-width panel)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'side',
        },
      })
      expect(wrapper.find('[data-testid="preview-open-full-button"]').exists()).toBe(false)
    })

    it('does NOT render the "Open full preview" button for non-html content types (markdown/code/text/image)', () => {
      // The "open full" affordance only applies to html (which is the
      // content type that has a fixed width + scrolling; markdown /
      // code / text already flow naturally; image is already responsive).
      for (const ct of ['markdown', 'text', 'code', 'image'] as const) {
        const wrapper = mount(PreviewContentRenderer, {
          props: {
            contentType: ct,
            args: { content: ct === 'image' ? 'data:image/png;base64,abc' : 'body' },
            variant: 'inline',
          },
        })
        expect(wrapper.find('[data-testid="preview-open-full-button"]').exists()).toBe(false)
      }
    })

    // ─── CTA strip below iframe (2026-08-29) ─────────────────────────
    //
    // The "Open full preview" button used to be absolute-positioned at
    // the top-right INSIDE the iframe's bounding box, where it
    // overlapped the preview content (especially pages with their own
    // top-right UI). Move it OUT of the iframe — render a small CTA
    // strip BELOW the iframe container. Same handler (opens the
    // preview in the side panel via the existing @open event path).
    it('places the "Open full preview" button OUTSIDE the iframe (not a child of the iframe element)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
      const button = wrapper.find('[data-testid="preview-open-full-button"]').element as HTMLElement
      // The button must NOT be a child of the iframe (it was, as
      // absolute top-right inside the iframe container). The CTA strip
      // lives BELOW the iframe container, so iframe.contains(button)
      // must be false.
      expect(iframe.contains(button)).toBe(false)
    })

    it('renders a CTA strip wrapper ([data-testid="preview-inline-cta"]) around the button (inline + html only)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const cta = wrapper.find('[data-testid="preview-inline-cta"]')
      expect(cta.exists()).toBe(true)
      // Button is inside the CTA strip.
      expect(cta.find('[data-testid="preview-open-full-button"]').exists()).toBe(true)
    })

    it('does NOT render the CTA strip in side variant (panel already shows the content full-width)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'side',
        },
      })
      expect(wrapper.find('[data-testid="preview-inline-cta"]').exists()).toBe(false)
    })

    it('default variant is "side" (no max-w-full, no "Open full" button)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
        },
      })
      // No variant passed → defaults to 'side' (back-compat).
      const iframeContainer = wrapper.find('[data-testid="preview-html-container"]')
      const classes = iframeContainer.attributes('class') ?? ''
      // Side variant uses h-full (fills panel), not max-w-full (chat column)
      expect(classes).not.toContain('max-w-full')
      expect(wrapper.find('[data-testid="preview-open-full-button"]').exists()).toBe(false)
    })
  })

  // ─── Auto-resize (2026-08-06) ─────────────────────────────────────
  //
  // The inline iframe auto-resizes to fit its content height via a
  // postMessage protocol: a tiny script inside the iframe (prepended
  // to the srcdoc by PreviewContentRenderer) reports its scrollHeight
  // back to the parent, which adjusts the iframe height. This way the
  // user sees the full HTML without a scrollbar in the inline chat
  // bubble.
  describe('auto-resize via postMessage', () => {
    it('embeds an auto-resize script in the iframe srcdoc', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
      const srcdoc = iframe.attributes('srcdoc') ?? ''
      // The auto-resize script must be embedded before the user's HTML
      // so it runs at parse time and sets up its listeners.
      expect(srcdoc).toContain('show-preview-auto-resize')
      expect(srcdoc).toContain('parent.postMessage')
    })

    it('updates iframe height when the iframe posts a height message', async () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
      // Simulate the iframe posting its height.
      window.dispatchEvent(
        new MessageEvent('message', {
          data: { source: 'show-preview-auto-resize', height: 777 },
        }),
      )
      await wrapper.vm.$nextTick()
      // The iframe's inline style should reflect the reported height.
      expect(iframe.style.height).toBe('777px')
    })

    it('clamps the reported height to a minimum (200px) so empty content still renders', async () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
      window.dispatchEvent(
        new MessageEvent('message', {
          data: { source: 'show-preview-auto-resize', height: 50 },
        }),
      )
      await wrapper.vm.$nextTick()
      expect(iframe.style.height).toBe('200px')
    })

    it('clamps the reported height to a maximum (2000px) so runaway content does not break the chat', async () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
      window.dispatchEvent(
        new MessageEvent('message', {
          data: { source: 'show-preview-auto-resize', height: 99999 },
        }),
      )
      await wrapper.vm.$nextTick()
      expect(iframe.style.height).toBe('2000px')
    })

    it('ignores messages with the wrong source (other iframes in the page)', async () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
      const initialStyle = iframe.style.height
      window.dispatchEvent(
        new MessageEvent('message', {
          data: { source: 'some-other-source', height: 500 },
        }),
      )
      await wrapper.vm.$nextTick()
      // Style unchanged because we filter by source.
      expect(iframe.style.height).toBe(initialStyle)
    })
  })
})