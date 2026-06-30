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

import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import PreviewSidePanel from '../components/PreviewSidePanel.vue'

interface PreviewOverrides {
  id?: string
  content?: string
  parameters?: string
}

interface PreviewInput {
  content_type?: 'markdown' | 'text' | 'code' | 'image'
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
 */
const buildEnvelope = (input: PreviewInput): string => {
  const parameters = JSON.stringify(input)
  const innerData = `<show_preview><status>shown</status><preview_id>pv_test_1</preview_id><content_type>${input.content_type ?? 'markdown'}</content_type><content_length>${input.content?.length ?? 0}</content_length></show_preview>`
  return `<tool><name>show_preview</name><parameters>${parameters}</parameters><success>true</success><data>${innerData}</data></tool>`
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
})