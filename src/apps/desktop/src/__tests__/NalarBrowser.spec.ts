/**
 * Tests for the nalar_browser tool-output component.
 *
 * The backend serializes every nalar_browser result as:
 *   <tool>
 *     <name>nalar_browser</name>
 *     <parameters>{ "action": "..." }</parameters>
 *     <success>true</success>
 *     <data>
 *       <success>1</success>
 *       <browser_id>...</browser_id>      (optional)
 *       <page_id>...</page_id>            (optional)
 *       <url>...</url>                    (optional)
 *       <title>...</title>                (optional)
 *       <status>200</status>              (optional)
 *       <tree>[{...}]</tree>              (optional, JSON string)
 *     </data>
 *   </tool>
 *
 * The parent (ChatView) unwraps the envelope via tryUnwrapToolOutput
 * and passes:
 *   - content    = inner <data> XML (success path) OR original content on error
 *   - parameters = JSON-string tool-call arguments
 *   - expanded   = whether the row is already expanded in the chat
 *
 * These tests focus on the header row and parameter parsing, NOT the
 * snapshot tree renderer (that's in Chunk 2).
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import NalarBrowser from '../components/tool_outputs/NalarBrowser.vue'

function mountNalarBrowser(props: {
  content: string
  parameters: string
  expanded?: boolean
}) {
  return mount(NalarBrowser, { props })
}

describe('NalarBrowser — action header', () => {
  it('renders "launch" header with browser_id from inner data', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success><browser_id>browser_abc123</browser_id>',
      parameters: JSON.stringify({ action: 'launch' }),
    })
    expect(wrapper.find('[data-testid="nalar-browser-header"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('launch')
    expect(wrapper.text()).toContain('browser_abc123')
  })

  it('renders "open_page" header with page title and URL', () => {
    const wrapper = mountNalarBrowser({
      content:
        '<success>1</success><page_id>page_xyz</page_id>' +
        '<url>https://example.com</url>' +
        '<title>Example Domain</title>' +
        '<status>200</status>',
      parameters: JSON.stringify({
        action: 'open_page',
        browser_id: 'browser_abc123',
        url: 'https://example.com',
      }),
    })
    expect(wrapper.text()).toContain('open_page')
    expect(wrapper.text()).toContain('Example Domain')
    expect(wrapper.text()).toContain('https://example.com')
  })

  it('renders "snapshot" header with element count from tree JSON', () => {
    const tree = [
      { ref: 'e1', text: 'Sign in' },
      { ref: 'e2', text: 'About', href: 'https://example.com/about' },
      { ref: 'e3', text: 'Contact' },
    ]
    const wrapper = mountNalarBrowser({
      content:
        '<success>1</success><page_id>page_xyz</page_id>' +
        '<url>https://example.com</url>' +
        '<title>Example Domain</title>' +
        `<tree>${JSON.stringify(tree)}</tree>`,
      parameters: JSON.stringify({ action: 'snapshot', page_id: 'page_xyz' }),
    })
    expect(wrapper.text()).toContain('snapshot')
    expect(wrapper.text()).toContain('3 elements')
  })

  it('renders "click" header with the ref that was clicked', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'click',
        page_id: 'page_xyz',
        ref: 'e12',
      }),
    })
    expect(wrapper.text()).toContain('click')
    expect(wrapper.text()).toContain('e12')
  })

  it('renders "fill" header with the ref and the text that was typed', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'fill',
        page_id: 'page_xyz',
        ref: 'e7',
        text: 'user@example.com',
      }),
    })
    expect(wrapper.text()).toContain('fill')
    expect(wrapper.text()).toContain('e7')
    expect(wrapper.text()).toContain('user@example.com')
  })

  it('renders "press" header with the key that was pressed', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'press',
        page_id: 'page_xyz',
        key: 'Enter',
      }),
    })
    expect(wrapper.text()).toContain('press')
    expect(wrapper.text()).toContain('Enter')
  })

  it('renders "close_page" header (no extra data)', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'close_page',
        page_id: 'page_xyz',
      }),
    })
    expect(wrapper.text()).toContain('close_page')
  })

  it('renders "close_browser" header with browser_id', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({
        action: 'close_browser',
        browser_id: 'browser_abc123',
      }),
    })
    expect(wrapper.text()).toContain('close_browser')
    expect(wrapper.text()).toContain('browser_abc123')
  })

  it('falls back to "unknown" action when parameters is not valid JSON', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success><browser_id>browser_abc</browser_id>',
      parameters: 'not json {{{',
    })
    expect(wrapper.find('[data-testid="nalar-browser-header"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('unknown')
    // The component must not crash; it should still show the browser_id.
    expect(wrapper.text()).toContain('browser_abc')
  })

  it('falls back to "unknown" action when parameters omits the action field', () => {
    const wrapper = mountNalarBrowser({
      content: '<success>1</success>',
      parameters: JSON.stringify({ browser_id: 'browser_abc' }),
    })
    expect(wrapper.text()).toContain('unknown')
  })
})
