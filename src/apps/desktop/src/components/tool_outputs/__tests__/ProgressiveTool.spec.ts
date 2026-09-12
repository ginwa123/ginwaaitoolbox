/**
 * Tests for ProgressiveTool.vue — universal renderer for
 * `search_tool` / `view_tool` / `use_tool`.
 *
 * Verifies (same expandable ToolCardHeader pattern as McpTool):
 *  - search_tool header shows query + tool count, rows render on expand
 *  - view_tool header shows name, description + pretty parameters on expand
 *  - use_tool header shows enabled/already-enabled, parameters on expand
 *  - error envelopes render the red error block
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ProgressiveTool from '../ProgressiveTool.vue'

const SEARCH_CONTENT =
  '<search_tool><query>kanban_list</query><count>3</count><total>3</total><tools>' +
  '<tool><name>kanban_list</name><kind>builtin</kind><server></server>' +
  '<equipped>no</equipped><summary>List a kanban board.</summary></tool>' +
  '</tools><hint>Call view_tool for the full parameter schema.</hint></search_tool>'

const VIEW_CONTENT =
  '<view_tool><name>kanban_list</name><kind>builtin</kind><server></server>' +
  '<equipped>no</equipped><description>List a kanban board.</description>' +
  '<parameters><![CDATA[{"type":"object","properties":{},"required":[]}]]></parameters>' +
  '<hint>Call use_tool with this name to enable it.</hint></view_tool>'

const USE_CONTENT =
  '<use_tool><name>kanban_list</name><kind>builtin</kind>' +
  '<equipped>true</equipped><inserted>true</inserted><wait_next_turn>true</wait_next_turn>' +
  '<parameters><![CDATA[{"type":"object","properties":{},"required":[]}]]></parameters>' +
  '<note>Enabled for this session.</note></use_tool>'

describe('ProgressiveTool', () => {
  it('renders search_tool rows on expand (same card pattern as other tools)', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: SEARCH_CONTENT,
        toolName: 'search_tool',
        parameters: '{}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('search_tool')
    expect(wrapper.text()).toContain('kanban_list')
    expect(wrapper.text()).toContain('List a kanban board.')
    expect(wrapper.attributes('data-testid') || wrapper.html()).toBeTruthy()
  })

  it('renders view_tool description + pretty parameters on expand', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: VIEW_CONTENT,
        toolName: 'view_tool',
        parameters: '{"name":"kanban_list"}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('view_tool')
    expect(wrapper.text()).toContain('kanban_list')
    expect(wrapper.text()).toContain('List a kanban board.')
    expect(wrapper.text()).toContain('"type": "object"')
  })

  it('renders use_tool enabled state + parameters on expand', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: USE_CONTENT,
        toolName: 'use_tool',
        parameters: '{"name":"kanban_list"}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('use_tool')
    expect(wrapper.text()).toContain('kanban_list')
    expect(wrapper.text()).toContain('enabled')
  })

  it('renders the error envelope', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content:
          '<view_tool><name>nope</name><found>false</found>' +
          '<error>unknown tool \'nope\' — not in this session\'s tool catalog</error>' +
          '<hint>Call search_tool to list candidates.</hint></view_tool>',
        toolName: 'view_tool',
        parameters: '{"name":"nope"}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('Error')
    expect(wrapper.text()).toContain('unknown tool')
  })

  it('collapses when expanded=false (header only, same as other cards)', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: SEARCH_CONTENT,
        toolName: 'search_tool',
        parameters: '{}',
        expanded: false,
      },
    })
    // Header is always visible…
    expect(wrapper.text()).toContain('search_tool')
    // …but rows stay hidden until expand.
    expect(wrapper.text()).not.toContain('List a kanban board.')
  })
})
