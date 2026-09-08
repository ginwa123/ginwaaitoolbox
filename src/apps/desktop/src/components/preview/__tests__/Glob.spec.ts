/**
 * Tests for Glob.vue — the chatview tool card for the `glob` agent tool.
 *
 * Locks in the 2026-08-23 de-bubble migration (task_1787481940400_1):
 *  - The root element MUST carry the shared `.chat-tool-card` class
 *    (defined :deep in ChatView.vue + SubAgentPeekPanel.vue) so glob
 *    renders like every other de-bubbled tool card (bash, search, …)
 *    instead of the old boxed bubble frame.
 *  - The old scoped bubble frame (.gl: border-radius 6px, box border,
 *    card background) MUST be gone.
 *  - Warning envelopes (<warning>...</warning>) still render the warning
 *    text and bind the orange left-rule variant.
 */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { defineComponent, h, provide } from 'vue'

import Glob from '../Glob.vue'
import {
  OPEN_IN_CODE_EDITOR_KEY,
  type OpenInCodeEditorFn,
} from '@/composables/useCodeEditor'

// ────────────────────────────────────────────────────────────────────────
// Test fixtures — match the wire shape emitted by the glob tool
// (`<glob pattern="..." path="...">…<f>path</f>…</glob>`).
// ────────────────────────────────────────────────────────────────────────

const matchEnvelope = (
  pattern = '**/*.zig',
  total = 3,
) =>
  `<glob pattern="${pattern}" path="/tmp/repo">\n` +
  `<glob_summary total="${total}" returned="${total}" offset="0" truncated_by_size="0">\n` +
  `<f>/tmp/repo/src/a.zig</f>\n` +
  `<f>/tmp/repo/src/b.zig</f>\n` +
  `<f>/tmp/repo/src/c.zig</f>\n` +
  `</glob_summary>\n</glob>\n`

const noMatchEnvelope = (
  pattern = 'needle_NOT_FOUND',
  path = '/tmp/repo/src',
) =>
  `<glob pattern="${pattern}" path="${path}">\n` +
  `<warning>no files found matching pattern "${pattern}" in path "${path}"</warning>\n` +
  `</glob>\n`

const makeWrapper = (
  props: { content: string; cwd?: string; expanded?: boolean; parameters?: string },
  provideOpenInEditor?: OpenInCodeEditorFn,
) => {
  if (provideOpenInEditor) {
    return mount(
      defineComponent({
        setup() {
          provide(OPEN_IN_CODE_EDITOR_KEY, provideOpenInEditor)
          return () => h(Glob, props as never)
        },
      }),
    )
  }
  return mount(Glob, { props: props as never })
}

afterEach(() => {
  document.body.innerHTML = ''
})

// ────────────────────────────────────────────────────────────────────────
// De-bubble contract — the whole point of this migration
// ────────────────────────────────────────────────────────────────────────

describe('Glob.vue — de-bubble contract (renders like bash/ShellTool)', () => {
  it('root element carries the shared .chat-tool-card class', () => {
    const wrapper = makeWrapper({ content: matchEnvelope() })
    expect(wrapper.find('.chat-tool-card').exists()).toBe(true)
  })

  it('root element does NOT carry the old bubble classes', () => {
    const wrapper = makeWrapper({ content: matchEnvelope() })
    expect(wrapper.find('.gl').exists()).toBe(false)
    expect(wrapper.find('.gl-header').exists()).toBe(false)
    expect(wrapper.find('.gl--warning').exists()).toBe(false)
  })

  it('source has no leftover bubble-frame CSS (border-radius/card-bg on a .gl root)', () => {
    // Read the component source and assert the old frame block is gone.
    // This is the static half of the contract — the DOM assertions above
    // are the rendered half.
    const src = readFileSync(resolve(__dirname, '../Glob.vue'), 'utf8')
    expect(src).toContain('.chat-tool-card')
    expect(src).not.toContain('border-radius: 6px')
    expect(src).not.toContain('background: var(--semantic-card-bg)')
    expect(src).not.toContain('.gl--warning')
  })

  it('warning variant binds border-orange-500/50 like ShellTool does', () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope() })
    const root = wrapper.find('.chat-tool-card')
    expect(root.exists()).toBe(true)
    expect(root.classes()).toContain('border-orange-500/50')
  })

  it('header keeps the violet glob pill + pattern after migration', () => {
    const wrapper = makeWrapper({ content: matchEnvelope('**/*.zig') })
    const html = wrapper.html()
    expect(html).toContain('glob')
    expect(html).toContain('**/*.zig')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Behaviour preserved from pre-migration
// ────────────────────────────────────────────────────────────────────────

describe('Glob.vue — behaviour preserved', () => {
  it('shows file count summary for match results', () => {
    const wrapper = makeWrapper({ content: matchEnvelope() })
    expect(wrapper.html()).toContain('3 files')
  })

  it('renders the warning text from <warning>...</warning>', () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope() })
    const html = wrapper.html()
    expect(html).toContain('no files found matching pattern')
    expect(html).toContain('needle_NOT_FOUND')
  })

  it('expands to show file paths on header click', async () => {
    const wrapper = makeWrapper({ content: matchEnvelope() })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.html()).toContain('/tmp/repo/src/a.zig')
  })

  it('does not expand when there is nothing to show (warning envelope)', async () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope() })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.html()).not.toContain('/tmp/repo/src/a.zig')
  })

  it('shows only copy buttons (no editor button) when no cwd prop', async () => {
    const wrapper = makeWrapper({ content: matchEnvelope() })
    await wrapper.find('[role="button"]').trigger('click')
    // 1 copy button per file row; the editor button requires cwd + injected handler.
    expect(wrapper.findAll('.gl-copy').length).toBe(3)
  })

  it('calls openInEditor with filePath + cwd when editor button clicked', async () => {
    const calls: { filePath: string; cwd: string }[] = []
    const fakeOpen: OpenInCodeEditorFn = async (opts) => {
      calls.push({ filePath: opts.filePath, cwd: opts.cwd })
    }
    const wrapper = makeWrapper(
      { content: matchEnvelope(), cwd: '/tmp/repo' },
      fakeOpen,
    )
    await wrapper.find('[role="button"]').trigger('click')
    const buttons = wrapper.findAll('.gl-copy')
    expect(buttons.length).toBeGreaterThanOrEqual(2)
    await buttons[buttons.length - 1]!.trigger('click')
    expect(calls).toEqual([{ filePath: '/tmp/repo/src/c.zig', cwd: '/tmp/repo' }])
  })
})

// ────────────────────────────────────────────────────────────────────────
// Empty/no-match results — Arguments must still be reachable.
//
// Bug: the expanded body was `v-if="isExpanded && filePaths.length > 0"`
// and toggle() refused to expand on a warning/empty envelope, so a no-match
// glob (warning envelope) could never show its Arguments block.
// ────────────────────────────────────────────────────────────────────────

describe('Glob.vue — warning envelope still shows Arguments (empty/no-match)', () => {
  const warningContent =
    `<glob pattern="foo" path="/tmp">\n` +
    `<warning>no matches for pattern</warning>\n` +
    `</glob>\n`
  const params = `<pattern>foo</pattern><path>/tmp</path>`

  it('shows Arguments when expanded via prop', () => {
    const wrapper = makeWrapper({ content: warningContent, parameters: params, expanded: true })

    const html = wrapper.html()
    expect(html).toContain('Arguments')
    expect(html).toContain('foo')
  })

  it('shows Arguments after header click', async () => {
    const wrapper = makeWrapper({ content: warningContent, parameters: params })

    // Collapsed initially: Arguments hidden.
    expect(wrapper.html()).not.toContain('Arguments')
    await wrapper.find('[role="button"]').trigger('click')
    const html = wrapper.html()
    expect(html).toContain('Arguments')
    expect(html).toContain('foo')
  })
})
