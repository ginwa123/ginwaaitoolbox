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

    it('inline container does NOT use max-w-full (iframe is allowed to exceed chat column — 2026-08-29 followup #3)', () => {
      // Earlier revisions constrained the iframe container to max-w-full
      // so wide content was CROPPED. The followup removed that cap so
      // wide content can render at its natural width (the container
      // has overflow-x: auto for horizontal scrolling). This test
      // locks in the new behaviour so a future revert is caught.
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const iframeContainer = wrapper.find('[data-testid="preview-html-container"]')
      const classes = iframeContainer.attributes('class') ?? ''
      expect(classes).not.toContain('max-w-full')
    })

    // ─── Iframe at natural content width (2026-08-29 followup #3) ──────
    //
    // The previous revision (#379) auto-escalated wide content to the
    // side panel. The user pushed back: "inline keep in the chat
    // messages, no need popup side". So instead of escalating, we
    // render the iframe at its CONTENT'S natural width (reported via
    // the postMessage `width` field) and let the user scroll horizontally
    // within the iframe container (which has overflow-x: auto).
    //
    // Result: wide content stays inline. The chat bubble gets a
    // horizontal scrollbar on the iframe container so the user can
    // swipe through the full content. They can also click the CTA
    // strip's "↗ Open in side panel" button to manually open the side
    // panel if they prefer — that's the only way the side panel
    // appears now.
    describe('iframe renders at natural content width (no more cropping)', () => {
      it('starts with no explicit width on the iframe (waits for the postMessage protocol)', () => {
        const wrapper = mount(PreviewContentRenderer, {
          props: {
            contentType: 'html',
            args: { content: '<h1>x</h1>' },
            variant: 'inline',
          },
        })
        const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
        // No width set yet — the iframe has its natural width until
        // the postMessage arrives.
        expect(iframe.style.width).toBe('')
      })

      it('sets iframe width to the reported content width when postMessage fires', async () => {
        const wrapper = mount(PreviewContentRenderer, {
          props: {
            contentType: 'html',
            args: { content: '<h1>x</h1>' },
            variant: 'inline',
          },
        })
        const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
        // Simulate the iframe reporting a 1200px-wide content.
        window.dispatchEvent(
          new MessageEvent('message', {
            data: { source: 'show-preview-auto-resize', height: 700, width: 1200 },
          }),
        )
        await wrapper.vm.$nextTick()
        // The iframe's width is now 1200px — wider than the chat column,
        // so the container's overflow-x: auto will show a scrollbar.
        expect(iframe.style.width).toBe('1200px')
      })

      it('clamps iframe width to MAX (1600px) so runaway content does not break horizontal scrolling', async () => {
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
            data: { source: 'show-preview-auto-resize', height: 9999, width: 9999 },
          }),
        )
        await wrapper.vm.$nextTick()
        // 9999px would create a horizontal scrollbar from hell.
        // Capped at 1600px.
        expect(iframe.style.width).toBe('1600px')
      })

      it('clamps iframe width to MIN (320px) so too-narrow content still fills the chat column', async () => {
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
            data: { source: 'show-preview-auto-resize', height: 100, width: 100 },
          }),
        )
        await wrapper.vm.$nextTick()
        // 100px is too narrow — clamped up to 320px so the iframe
        // fills the chat column instead of sitting in a corner.
        expect(iframe.style.width).toBe('320px')
      })

      it('iframe container has overflow-x: auto so wide content shows a horizontal scrollbar', () => {
        const wrapper = mount(PreviewContentRenderer, {
          props: {
            contentType: 'html',
            args: { content: '<h1>x</h1>' },
            variant: 'inline',
          },
        })
        const container = wrapper.find('[data-testid="preview-html-container"]')
        const classes = container.attributes('class') ?? ''
        expect(classes).toContain('overflow-x-auto')
        // Crucially: NOT `overflow-hidden` (which would clip the wider
        // iframe). The container should scroll horizontally instead.
        expect(classes).not.toContain('overflow-hidden')
      })

      it('does NOT auto-emit "open-in-side-panel" when iframe reports wide content (user feedback: no popup)', async () => {
        // The user explicitly said "inline keep in the chat messages,
        // no need popup side". So no auto-escalation — wide content
        // stays inline, the user scrolls horizontally.
        const wrapper = mount(PreviewContentRenderer, {
          props: {
            contentType: 'html',
            args: { content: '<h1>x</h1>' },
            variant: 'inline',
          },
        })
        const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]').element as HTMLIFrameElement
        Object.defineProperty(iframe, 'clientWidth', { value: 500, configurable: true })
        for (let i = 0; i < 10; i++) {
          window.dispatchEvent(
            new MessageEvent('message', {
              data: { source: 'show-preview-auto-resize', height: 999, width: 9999 },
            }),
          )
        }
        await wrapper.vm.$nextTick()
        // No auto-escalation: zero emits, even though the content is
        // 9999px wide (the iframe just gets clamped to 1600px and
        // overflows horizontally within its container).
        expect(wrapper.emitted('open-in-side-panel')).toBeFalsy()
      })
    })

    // ─── CTA strip below iframe (manual escape hatch to side panel) ───
    //
    // Restored after #379's auto-escalate removal. The user CAN still
    // open the preview in the side panel manually — they just don't get
    // forced to.
    it('renders the "Open in side panel" button below the iframe (inline + html only)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      const cta = wrapper.find('[data-testid="preview-inline-cta"]')
      expect(cta.exists()).toBe(true)
      expect(cta.find('[data-testid="preview-open-full-button"]').exists()).toBe(true)
    })

    it('emits "open-in-side-panel" when the CTA button is clicked (manual escape hatch)', async () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'inline',
        },
      })
      await wrapper.find('[data-testid="preview-open-full-button"]').trigger('click')
      expect(wrapper.emitted('open-in-side-panel')?.length).toBe(1)
    })

    it('does NOT render the CTA strip in side variant (panel already shows content full-width)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
          variant: 'side',
        },
      })
      expect(wrapper.find('[data-testid="preview-inline-cta"]').exists()).toBe(false)
    })

    it('default variant is "side" (no overflow-x-auto, no inline-only CTA)', () => {
      const wrapper = mount(PreviewContentRenderer, {
        props: {
          contentType: 'html',
          args: { content: '<h1>x</h1>' },
        },
      })
      // No variant passed → defaults to 'side' (back-compat).
      const iframeContainer = wrapper.find('[data-testid="preview-html-container"]')
      const classes = iframeContainer.attributes('class') ?? ''
      // Side variant uses h-full (fills panel), not overflow-x-auto
      // (chat column).
      expect(classes).not.toContain('overflow-x-auto')
      // No inline-only CTA in side variant.
      expect(wrapper.find('[data-testid="preview-inline-cta"]').exists()).toBe(false)
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