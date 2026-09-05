/**
 * Tests for ShellTool.vue — in-progress (placeholder) rendering.
 *
 * Regression: while a shell tool (bash/pwsh/command) is still running,
 * the backend has only emitted the Phase-1 placeholder envelope
 * (handle_tool.zig: empty `<data></data>`). ShellTool only read
 * `:content` (inner data) so `parsed.command` was null and the header
 * showed `$ unknown` for the whole run (screenshot: `command $ unknown +`).
 *
 * The tool-call arguments (JSON `{"command":"..."}`) ARE available in
 * the outer `<tool><parameters>` envelope — ChatView unwraps them via
 * `getParametersForMessage`. ShellTool must accept `:parameters` and
 * fall back to `parameters.command` while in-progress, with a running
 * indicator, instead of `unknown`.
 */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import ShellTool from '../ShellTool.vue'

const completedEnvelope =
  `<command>echo hi</command>` +
  `<stdout>hi</stdout><stderr></stderr>` +
  `<exit_code>0</exit_code><truncated>false</truncated>` +
  `<timeout>false</timeout><stdout_lines>1</stdout_lines>` +
  `<stderr_lines>0</stderr_lines><is_self>false</is_self>`

const emptyPlaceholder = ''

const paramsFor = (command: string) => JSON.stringify({ command })

const makeWrapper = (props: {
  content: string
  toolName?: string
  parameters?: string
  expanded?: boolean
}) =>
  mount(ShellTool, {
    props: {
      toolName: 'command',
      ...props,
    } as never,
  })

afterEach(() => {
  document.body.innerHTML = ''
})

describe('ShellTool.vue — in-progress placeholder (TDD: unknown bug)', () => {
  it('shows the command from :parameters when :content is empty (running), not "unknown"', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: paramsFor('sleep 10'),
    })
    const html = wrapper.html()
    expect(html).toContain('sleep 10')
    expect(html).not.toContain('unknown')
  })

  it('shows a running indicator while exit_code is missing (in-progress)', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: paramsFor('sleep 10'),
    })
    const html = wrapper.html()
    // running badge — exact copy is "running" (pulsing dot via CSS)
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers :content command over :parameters once completed', () => {
    const wrapper = makeWrapper({
      content: completedEnvelope,
      parameters: paramsFor('stale command from args'),
    })
    const html = wrapper.html()
    expect(html).toContain('echo hi')
    expect(html).not.toContain('stale command from args')
  })

  it('falls back to "unknown" only when BOTH content and parameters lack a command', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: '{}',
    })
    expect(wrapper.html()).toContain('unknown')
  })

  it('does NOT show the running indicator once exit_code is present (completed)', () => {
    const wrapper = makeWrapper({
      content: completedEnvelope,
      parameters: paramsFor('echo hi'),
    })
    expect(wrapper.html().toLowerCase()).not.toContain('running')
  })

  it('shows command from XML :parameters when :content empty', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: '<command>sleep 10</command><mandatory_timeout>30</mandatory_timeout>',
    })
    const html = wrapper.html()
    expect(html).toContain('sleep 10')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers envelope command over XML parameters', () => {
    const wrapper = makeWrapper({
      content: completedEnvelope,
      parameters: '<command>stale</command>',
    })
    const html = wrapper.html()
    expect(html).toContain('echo hi')
    expect(html).not.toContain('stale')
  })
})
