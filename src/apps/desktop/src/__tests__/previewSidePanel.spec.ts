/**
 * Tests for PreviewSidePanel — the side panel that renders
 * `show_preview` agent tool results in the chat UI.
 *
 * Covers:
 *   - Empty-state: renders nothing when no previews are present.
 *   - Single preview: markdown / image / code rendering via `marked()`,
 *     `<img>`, and `<pre><code class="language-X">`.
 *   - Multi-preview: tab strip + auto-switch to newest on append.
 *   - UX: collapse and dismiss events.
 *
 * The component does NOT use Pinia, so no `setActivePinia` setup is needed.
 * The data-testid selectors come from the component's template attributes.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import PreviewSidePanel from '../components/preview/PreviewSidePanel.vue'

interface PreviewOverrides {
  id?: string
  content?: string
  parameters?: string
}

interface PreviewInput {
  content_type?: 'markdown' | 'text' | 'code' | 'image' | 'html'
  content?: string
  title?: string
  language?: string
  caption?: string
}

/**
 * Build the `<tool>...</tool>` envelope that the backend actually
 * stores in `llm_history.response_content` (see tool_registry.wrapToolOutput).
 * `PreviewSidePanel` uses `tryUnwrapToolOutput` to pull `parameters`
 * out of this envelope, so the test fixtures must produce the
 * real envelope shape — not a synthetic `{content, parameters}` object.
 *
 * This variant embeds the parameters as **raw JSON** inside
 * `<parameters>...</parameters>`. Most tests use this form because
 * it's simpler; the production-pipeline form is `buildXmlEnvelope`
 * below (which mirrors what jsonArgsToXml produces after the
 * double-wrap fix — see tool_registry.zig:1581).
 */
const buildEnvelope = (input: PreviewInput): string => {
  const parameters = JSON.stringify(input)
  const innerData = `<show_preview><status>shown</status><preview_id>pv_test_1</preview_id><content_type>${input.content_type ?? 'markdown'}</content_type><content_length>${input.content?.length ?? 0}</content_length></show_preview>`
  return `<tool><name>show_preview</name><parameters>${parameters}</parameters><success>true</success><data>${innerData}</data></tool>`
}

/**
 * Build a `<tool>...</tool>` envelope where the inner `<parameters>`
 * is XML (the form produced by the backend's `jsonArgsToXml` after
 * the double-wrap fix), not raw JSON. Each JSON key becomes a
 * child tag: `{"content_type":"markdown","content":"hi"}` →
 * `<parameters><content_type>markdown</content_type><content>hi</content></parameters>`.
 *
 * The frontend MUST extract these via `findTag(...)`, not `JSON.parse`,
 * because `<` and `>` are not escaped inside JSON string values that
 * happen to contain markdown/code.
 */
const buildXmlEnvelope = (input: PreviewInput): string => {
  const paramsInner = Object.entries(input)
    .map(([k, v]) => {
      // Escape any XML-incompatible chars in the value (defensive —
      // the backend's xmlEscape covers & < > " ' but the test only
      // needs & and <, which are the ones that would break findTag).
      const escaped = String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      return `<${k}>${escaped}</${k}>`
    })
    .join('')
  const innerData = `<show_preview><status>shown</status><preview_id>pv_test_1</preview_id><content_type>${input.content_type ?? 'markdown'}</content_type><content_length>${input.content?.length ?? 0}</content_length></show_preview>`
  return `<tool><name>show_preview</name><parameters>${paramsInner}</parameters><success>true</success><data>${innerData}</data></tool>`
}

const makePreview = (overrides: PreviewOverrides = {}) => {
  const parameters = overrides.parameters
    ? JSON.parse(overrides.parameters)
    : { content_type: 'markdown', content: '# Hello' }
  return {
    id: overrides.id ?? 'msg-1',
    content:
      overrides.content ??
      buildEnvelope(parameters as PreviewInput),
  }
}

describe('PreviewSidePanel', () => {
  // Clear localStorage before each test so the resize-persistence
  // tests don't see stale values from prior tests. The 15 tests
  // above don't touch localStorage but they aren't affected by
  // a clear (the panel doesn't read localStorage today).
  //
  // localStorage is undefined in some Vitest environments — guard
  // with `vi.stubGlobal` (matches NalarBrowserInlinePreview.spec.ts:13-22)
  // so this works under jsdom AND any environment that lacks the global.
  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => { store[k] = String(v) },
        removeItem: (k: string) => { delete store[k] },
        clear: () => { for (const k in store) delete store[k] },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }
  })

  it('renders nothing when previews array is empty', () => {
    const wrapper = mount(PreviewSidePanel, { props: { previews: [] } })
    expect(wrapper.find('[data-testid="preview-side-panel"]').exists()).toBe(false)
  })

  it('renders panel when one preview is present', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    expect(wrapper.find('[data-testid="preview-side-panel"]').exists()).toBe(true)
  })

  it('renders markdown content via marked()', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          makePreview({
            parameters: JSON.stringify({ content_type: 'markdown', content: '# Title' }),
          }),
        ],
      },
    })
    const html = wrapper.html()
    expect(html).toContain('Title')
    expect(html).toContain('<h1')
  })

  it('renders image content as <img>', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          // Use buildEnvelope so the panel sees the full <tool> wrapper
          // with the <parameters> tag inside (production pipeline).
          {
            id: 'img-1',
            content: buildEnvelope({
              content_type: 'image',
              content: 'data:image/png;base64,iVBORw0KGgo=',
            }),
          },
        ],
      },
    })
    const img = wrapper.find('img')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toContain('data:image/png;base64')
  })

  it('renders code content with language class', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'code-1',
            content: buildEnvelope({
              content_type: 'code',
              content: 'fn main() void {}',
              language: 'zig',
            }),
          },
        ],
      },
    })
    expect(wrapper.html()).toContain('language-zig')
  })

  it('shows tabs when multiple previews are present', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          makePreview({ id: '1' }),
          makePreview({
            id: '2',
            parameters: JSON.stringify({ content_type: 'code', content: 'x', language: 'py' }),
          }),
        ],
      },
    })
    // Tab strip uses font-mono buttons (per PreviewSidePanel.vue template)
    const tabButtons = wrapper.findAll('button.font-mono')
    expect(tabButtons.length).toBeGreaterThanOrEqual(2)
  })

  it('auto-switches to the newest preview when one is added', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview({ id: '1' })] },
    })
    expect(wrapper.text()).toContain('markdown')

    await wrapper.setProps({
      previews: [
        makePreview({ id: '1' }),
        // Second preview via buildEnvelope so the full <tool> wrapper
        // is produced (matches production storage shape).
        {
          id: '2',
          content: buildEnvelope({
            content_type: 'code',
            content: 'x',
            language: 'py',
          }),
        },
      ],
    })
    await nextTick()
    // After auto-switch, the second (newest) preview's code block should
    // be visible. language-py appears in the rendered HTML.
    expect(wrapper.html()).toContain('language-py')
  })

  it('emits update:collapsed when collapse button is clicked', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const collapseBtn = wrapper.find('button[title="Collapse panel"]')
    expect(collapseBtn.exists()).toBe(true)
    await collapseBtn.trigger('click')
    expect(wrapper.emitted('update:collapsed')).toBeTruthy()
    expect(wrapper.emitted('update:collapsed')?.[0]).toEqual([true])
  })

  it('emits dismiss when dismiss button is clicked', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const dismissBtn = wrapper.find('button[title="Dismiss panel"]')
    expect(dismissBtn.exists()).toBe(true)
    await dismissBtn.trigger('click')
    expect(wrapper.emitted('dismiss')).toBeTruthy()
  })

  // Regression test for the critical bug caught in final review
  // (2026-07-01): if a future refactor removes the tryUnwrapToolOutput
  // call from PreviewSidePanel and reverts to reading a top-level
  // `parameters` field on the message, this test will catch it because
  // it passes a realistic message shape (full <tool> envelope, no
  // separate parameters prop).
  it('integrates with the full <tool> envelope pipeline (regression test)', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'real-1',
            content: buildEnvelope({
              content_type: 'markdown',
              content: '# Integration Test\n\nThis is real markdown.',
              title: 'Real Pipeline',
            }),
          },
        ],
      },
    })
    // Title rendered (proves parameters extraction works)
    expect(wrapper.text()).toContain('Real Pipeline')
    // Markdown rendered via marked (proves content extraction works)
    expect(wrapper.html()).toContain('<h1')
    expect(wrapper.html()).toContain('Integration Test')
    // content_type from inner envelope drives the header label
    expect(wrapper.text()).toContain('markdown')
  })

  // Regression test for the production pipeline: the backend's
  // jsonArgsToXml (tool_registry.zig:1581) converts each JSON key
  // into a child tag inside <parameters>, so the final envelope
  // is XML — NOT raw JSON. PreviewSidePanel must extract the
  // content/title/etc. via findTag, not JSON.parse. Without that
  // fix the panel renders empty (activeArgs === {} from a failed
  // JSON.parse).
  it('extracts parameters from XML-form <parameters> (production pipeline)', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'xml-1',
            content: buildXmlEnvelope({
              content_type: 'markdown',
              content: '# XML Pipeline\n\nRendered via findTag.',
              title: 'From XML Params',
            }),
          },
        ],
      },
    })
    // Title from <title>...</title> inside <parameters>...</parameters>
    expect(wrapper.text()).toContain('From XML Params')
    // Markdown content from <content>...</content> renders via marked
    expect(wrapper.html()).toContain('<h1')
    expect(wrapper.html()).toContain('XML Pipeline')
    // content_type from inner envelope drives the header
    expect(wrapper.text()).toContain('markdown')
  })

  it('renders code preview via XML parameters (production pipeline)', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'xml-code-1',
            content: buildXmlEnvelope({
              content_type: 'code',
              content: 'fn main() !void {}',
              language: 'zig',
            }),
          },
        ],
      },
    })
    // code renders as <pre><code class="language-zig">…</code></pre>
    expect(wrapper.html()).toContain('language-zig')
    expect(wrapper.html()).toContain('fn main')
  })

  // Regression tests for the bubble-click → panel-jump feature
  // (2026-07-01). When the parent (ChatView) sees a click on a
  // `show_preview` tool message bubble, it sets `focusId` to the
  // message id and clears `collapsed`/`dismissed`. The panel
  // must jump to the matching tab via the watcher.

  it('jumps activeIndex to the preview matching focusId', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'p-1',
            content: buildEnvelope({ content_type: 'text', content: 'first' }),
          },
          {
            id: 'p-2',
            content: buildEnvelope({ content_type: 'code', content: 'second', language: 'py' }),
          },
          {
            id: 'p-3',
            content: buildEnvelope({ content_type: 'markdown', content: '# third' }),
          },
        ],
      },
    })
    // Initial mount shows the FIRST preview (activeIndex default = 0;
    // the auto-switch watcher only fires when new previews arrive
    // after mount).
    expect(wrapper.text()).toContain('first')
    // Now the parent says "user clicked the bubble for p-3" — the panel
    // should jump to the third preview.
    await wrapper.setProps({ focusId: 'p-3' })
    await nextTick()
    expect(wrapper.text()).toContain('third')
    expect(wrapper.text()).not.toContain('first')
    // Clicking p-2 again must also work.
    await wrapper.setProps({ focusId: 'p-2' })
    await nextTick()
    expect(wrapper.html()).toContain('language-py')
    expect(wrapper.text()).not.toContain('third')
  })

  it('ignores focusId when it does not match any current preview', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [makePreview({ id: 'a' })],
        focusId: 'does-not-exist',
      },
    })
    await nextTick()
    // Panel still renders (does not crash), activeIndex stays at default
    expect(wrapper.find('[data-testid="preview-side-panel"]').exists()).toBe(true)
    // No fallback to "no preview" — the existing preview is still shown
    expect(wrapper.text()).toContain('markdown')
  })

  it('treats null focusId as no-op (does not change activeIndex)', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [makePreview({ id: 'a' })],
        focusId: 'a',
      },
    })
    await nextTick()
    expect(wrapper.text()).toContain('markdown')
    await wrapper.setProps({ focusId: null })
    await nextTick()
    // Same preview still shown
    expect(wrapper.text()).toContain('markdown')
  })

  // ─── Resize behavior (preview-panel-resize design) ─────────────────────
  //
  // These 5 tests cover the self-contained resize interaction:
  //   - Default 480px width when no localStorage value
  //   - Load from localStorage on mount
  //   - Persist to localStorage on drag release
  //   - Clamp at MIN_WIDTH = 240 when dragged past the bound
  //   - Hide the resize handle when the panel is collapsed
  //
  // Pattern follows AppLayout.kanban.spec.ts:384-468 (kanban column
  // resize persistence test). Dispatch mousemove/mouseup on
  // document.body (jsdom's closest proxy to `document`).
  //
  // The current (pre-implementation) code uses Tailwind `w-[480px]`
  // for the width, NOT an inline `style.width`, so these tests all
  // FAIL on current code:
  //   - Tests 1, 2, 4 read `style.width` which is "" on current code
  //   - Test 3 reads localStorage which is "" on current code (no persist)
  //   - Test 5 looks for `[data-testid="preview-resize-handle"]` which
  //     doesn't exist on current code

  it('uses 480px default width when no localStorage value exists', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const panel = wrapper.find('[data-testid="preview-side-panel"]')
    expect(panel.exists()).toBe(true)
    expect((panel.element as HTMLElement).style.width).toBe('480px')
  })

  it('loads width from localStorage on mount', () => {
    localStorage.setItem('nalar-preview-panel-width', '600')
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const panel = wrapper.find('[data-testid="preview-side-panel"]')
    expect((panel.element as HTMLElement).style.width).toBe('600px')
  })

  it('persists the new width to localStorage on drag release', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const handle = wrapper.find('[data-testid="preview-resize-handle"]')
    expect(handle.exists()).toBe(true)
    // mousedown at clientX=500 sets startX=500, startWidth=480 (default).
    // mousemove at clientX=700 (cursor moved RIGHT by 200px): the panel
    // is on the right, handle is on the LEFT edge, so moving the
    // cursor RIGHT shrinks the panel. delta = startX - clientX = -200,
    // newWidth = max(240, 480 + (-200)) = 280. Assert that stored
    // value is in [240, 480) — clamped and shrank from default.
    await handle.trigger('mousedown', { clientX: 500 })
    document.body.dispatchEvent(
      new MouseEvent('mousemove', { clientX: 700, bubbles: true }),
    )
    document.body.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    await nextTick()
    const stored = localStorage.getItem('nalar-preview-panel-width')
    expect(stored).not.toBeNull()
    const parsed = parseInt(stored!, 10)
    expect(parsed).toBeGreaterThanOrEqual(240)
    // Strict < (not <=) so a drag with zero net displacement fails — guards against the persist handler firing on every mousedown regardless of mousemove.
    expect(parsed).toBeLessThan(480)
  })

  it('clamps the width at MIN_WIDTH = 240 when dragged past the bound', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    const handle = wrapper.find('[data-testid="preview-resize-handle"]')
    // Drag the cursor far right (clientX 500 -> 5000 = +4500px right).
    // The handle's drag math would produce newWidth = 480 - 4500 = -4020,
    // which must clamp to MIN_WIDTH = 240. The clamp also gets persisted.
    await handle.trigger('mousedown', { clientX: 500 })
    document.body.dispatchEvent(
      new MouseEvent('mousemove', { clientX: 5000, bubbles: true }),
    )
    document.body.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
    await nextTick()
    const panel = wrapper.find('[data-testid="preview-side-panel"]')
    expect((panel.element as HTMLElement).style.width).toBe('240px')
    expect(localStorage.getItem('nalar-preview-panel-width')).toBe('240')
  })

  it('hides the resize handle when the panel is collapsed', async () => {
    const wrapper = mount(PreviewSidePanel, {
      props: { previews: [makePreview()] },
    })
    expect(wrapper.find('[data-testid="preview-resize-handle"]').exists()).toBe(true)
    await wrapper.find('button[title="Collapse panel"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="preview-resize-handle"]').exists()).toBe(false)
  })

  // ─── html content_type (sandboxed iframe) ───────────────────────────
  // Feature: show_preview.content_type="html" — renders inside a
  // sandboxed iframe matching the existing DesignElementPreview.vue
  // pattern. The iframe MUST have sandbox="allow-scripts" (no
  // allow-same-origin, no allow-forms) so the user's HTML/JS cannot
  // read the parent app's cookies or localStorage.

  it('renders html content_type inside a sandboxed iframe', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'html-1',
            content: buildEnvelope({
              content_type: 'html',
              content: '<h1>Hello</h1>',
              title: 'Landing page',
            }),
          },
        ],
      },
    })
    const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
    expect(iframe.exists()).toBe(true)
    expect(iframe.attributes('sandbox')).toBe('allow-scripts')
  })

  it('passes the user HTML into the iframe via srcdoc (raw HTML, browser handles encoding)', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'html-2',
            content: buildEnvelope({
              content_type: 'html',
              content: '<!DOCTYPE html><html><body><h1>Hi</h1></body></html>',
            }),
          },
        ],
      },
    })
    const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
    expect(iframe.exists()).toBe(true)
    const srcdoc = iframe.attributes('srcdoc') ?? ''
    // CRITICAL: the raw HTML must be present UN-escaped. The browser's
    // setAttribute() encodes < > & " for the attribute value, then the
    // iframe parser decodes them back when loading the document. If the
    // implementation manually escapes here, the iframe renders the
    // LITERAL text "&lt;p&gt;..." instead of the rendered "<p>...".
    // vue-test-utils' `.attributes('srcdoc')` returns the post-decode
    // value (per the HTML spec), so we see the raw HTML.
    expect(srcdoc).toContain('<!DOCTYPE html>')
    expect(srcdoc).toContain('<h1>Hi</h1>')
  })

  it('keeps double quotes in the user HTML intact (browser setAttribute handles them)', () => {
    const wrapper = mount(PreviewSidePanel, {
      props: {
        previews: [
          {
            id: 'html-3',
            content: buildEnvelope({
              content_type: 'html',
              content: '<a href="x" title="Y">link</a>',
            }),
          },
        ],
      },
    })
    const iframe = wrapper.find('iframe[data-testid="preview-html-iframe"]')
    expect(iframe.exists()).toBe(true)
    const srcdoc = iframe.attributes('srcdoc') ?? ''
    // The raw double quotes are preserved in the decoded attribute value.
    // The browser's setAttribute() encodes them as &quot; for the wire
    // format, but .attributes() returns the decoded text.
    expect(srcdoc).toContain('href="x"')
    expect(srcdoc).toContain('title="Y"')
  })

  // ─── Display mode toggle (2026-08-06) ───────────────────────────
  //
  // The new 2-button segmented control in the panel header lets
  // the user flip between rendering `show_preview` outputs in this
  // side panel ('side', default) versus inline in the chat bubble
  // ('inline'). The choice persists in localStorage. This is the
  // UX-driven equivalent of DiffView's split/unified toggle.
  describe('Display mode toggle', () => {
    it('renders both Side and Inline buttons in the panel header', () => {
      const wrapper = mount(PreviewSidePanel, {
        props: { previews: [makePreview()] },
      })
      expect(wrapper.find('[data-testid="preview-display-mode-toggle"]').exists()).toBe(true)
      expect(wrapper.find('[data-testid="preview-display-mode-side"]').exists()).toBe(true)
      expect(wrapper.find('[data-testid="preview-display-mode-inline"]').exists()).toBe(true)
    })

    it('marks "Side" as the active mode by default (when localStorage is empty)', () => {
      const wrapper = mount(PreviewSidePanel, {
        props: { previews: [makePreview()] },
      })
      const sideBtn = wrapper.find('[data-testid="preview-display-mode-side"]')
      const inlineBtn = wrapper.find('[data-testid="preview-display-mode-inline"]')
      expect(sideBtn.attributes('aria-pressed')).toBe('true')
      expect(inlineBtn.attributes('aria-pressed')).toBe('false')
    })

    it('marks "Inline" as the active mode when localStorage was set to "inline"', () => {
      localStorage.setItem('nalar-preview-display-mode', 'inline')
      const wrapper = mount(PreviewSidePanel, {
        props: { previews: [makePreview()] },
      })
      const sideBtn = wrapper.find('[data-testid="preview-display-mode-side"]')
      const inlineBtn = wrapper.find('[data-testid="preview-display-mode-inline"]')
      expect(sideBtn.attributes('aria-pressed')).toBe('false')
      expect(inlineBtn.attributes('aria-pressed')).toBe('true')
    })

    it('clicking "Inline" flips the active mode AND persists to localStorage', async () => {
      const wrapper = mount(PreviewSidePanel, {
        props: { previews: [makePreview()] },
      })
      const inlineBtn = wrapper.find('[data-testid="preview-display-mode-inline"]')
      await inlineBtn.trigger('click')
      await wrapper.vm.$nextTick()

      expect(inlineBtn.attributes('aria-pressed')).toBe('true')
      const sideBtn = wrapper.find('[data-testid="preview-display-mode-side"]')
      expect(sideBtn.attributes('aria-pressed')).toBe('false')
      expect(localStorage.getItem('nalar-preview-display-mode')).toBe('inline')
    })

    it('clicking "Side" flips back from inline AND persists to localStorage', async () => {
      localStorage.setItem('nalar-preview-display-mode', 'inline')
      const wrapper = mount(PreviewSidePanel, {
        props: { previews: [makePreview()] },
      })
      // Sanity check: started in inline mode.
      expect(
        wrapper.find('[data-testid="preview-display-mode-inline"]').attributes('aria-pressed'),
      ).toBe('true')

      const sideBtn = wrapper.find('[data-testid="preview-display-mode-side"]')
      await sideBtn.trigger('click')
      await wrapper.vm.$nextTick()

      expect(sideBtn.attributes('aria-pressed')).toBe('true')
      expect(
        wrapper.find('[data-testid="preview-display-mode-inline"]').attributes('aria-pressed'),
      ).toBe('false')
      expect(localStorage.getItem('nalar-preview-display-mode')).toBe('side')
    })

    it('clicking the already-active mode is a no-op (no write storm)', async () => {
      const wrapper = mount(PreviewSidePanel, {
        props: { previews: [makePreview()] },
      })
      const sideBtn = wrapper.find('[data-testid="preview-display-mode-side"]')
      // Already 'side' — clicking again should not change anything.
      await sideBtn.trigger('click')
      await wrapper.vm.$nextTick()
      expect(sideBtn.attributes('aria-pressed')).toBe('true')
      expect(localStorage.getItem('nalar-preview-display-mode')).not.toBe('inline')
    })
  })
})