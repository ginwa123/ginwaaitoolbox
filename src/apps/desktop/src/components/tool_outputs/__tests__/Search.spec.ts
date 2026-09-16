/**
 * Tests for Search.vue — the chatview toast card for the `search` agent tool.
 *
 * Locks in the operator-visible behaviour that fixes the
 * "unknown pattern not found" rendering bug:
 *  - When the wire envelope contains `<search pattern="X" path="Y">`,
 *    the header MUST show `"X"` and `in Y` (not the literal "unknown").
 *  - When the wire envelope contains a `<warning>` (no-match warning),
 *    the warning text MUST appear in the header's right-hand side.
 *  - The default view MUST stay minimal — the operator can click to
 *    expand and see the full Raw Input XML (handled by the surrounding
 *    ChatView parent, not Search.vue itself).
 *
 * See docs/superpowers/plans/2026-08-06-search-better-error.md.
 */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'
import { defineComponent, h, provide } from 'vue'

import Search from '../Search.vue'
import { OPEN_IN_CODE_EDITOR_KEY, type OpenInCodeEditorFn } from '@/composables/useCodeEditor'

// ────────────────────────────────────────────────────────────────────────
// Test fixtures — match the wire shape emitted by
// search_result_to_string_{grouped,flat} in src/modules/agent/tools/search.zig
// ────────────────────────────────────────────────────────────────────────

/**
 * No-match envelope: `<search pattern="X" path="Y">` opens,
 * `<warning>no matches for pattern "X" in path "Y"</warning>` body,
 * `</search>` closes. Matches what the backend emits after the
 * 2026-08-06 search-better-error fix.
 */
const noMatchEnvelope = (pattern = 'needle_NOT_FOUND', path = '/tmp/repo/src') =>
  `<search pattern="${pattern}" path="${path}">\n` +
  `<warning>no matches for pattern "${pattern}" in path "${path}"</warning>\n` +
  `</search>\n`

/**
 * One-match envelope: `<search pattern="X" path="Y">` opens, file block
 * inside, closes.
 */
const oneMatchEnvelope = (pattern = 'TODO', path = '/tmp/repo/src') =>
  `<search pattern="${pattern}" path="${path}">\n` +
  `<file path="/tmp/repo/src/foo.ts" total="100" count="1">\n` +
  `  <m><l>42</l><s>    // TODO: fix this</s></m>\n` +
  `</file>\n` +
  `</search>\n`

const makeWrapper = (
  props: { content: string; cwd?: string; expanded?: boolean; parameters?: string },
  provideOpenInEditor?: OpenInCodeEditorFn,
) => {
  if (provideOpenInEditor) {
    return mount(
      defineComponent({
        setup() {
          provide(OPEN_IN_CODE_EDITOR_KEY, provideOpenInEditor)
          return () => h(Search, props as never)
        },
      }),
    )
  }
  return mount(Search, { props: props as never })
}

afterEach(() => {
  document.body.innerHTML = ''
})

// ────────────────────────────────────────────────────────────────────────
// Header rendering — the operator's first-glance view of what was searched
// ────────────────────────────────────────────────────────────────────────

describe('Search.vue — header rendering (operator-visible pattern + path)', () => {
  it('shows the actual pattern from the envelope, not "unknown" (regression: bug 2026-08-06)', () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope('needle_NOT_FOUND', '/tmp/x') })

    // The pattern text appears inside quotes in the header. Specifically
    // NOT the literal "unknown" that the pre-fix wire envelope (no
    // <search pattern="..."> wrapper) produced.
    const html = wrapper.html()
    expect(html).toContain('needle_NOT_FOUND')
    // The header should NOT fall back to "unknown" because the envelope
    // carries pattern="needle_NOT_FOUND".
    expect(html).not.toContain('"unknown"')
  })

  it('shows the actual path from the envelope, not "unknown"', () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope('foo', '/repo/path/src') })

    const html = wrapper.html()
    expect(html).toContain('in /repo/path/src')
    // The "in unknown" fallback would render if `searchPath` regex
    // returned null. With the new backend wrapper it MUST return the
    // real path.
    expect(html).not.toContain('in unknown')
  })

  it('renders both the pattern and the path together in the header', () => {
    const wrapper = makeWrapper({
      content: noMatchEnvelope('readFileAlloc|readFile', '/home/ginwa/repo/src/modules'),
    })

    const html = wrapper.html()
    expect(html).toContain('readFileAlloc|readFile')
    expect(html).toContain('/home/ginwa/repo/src/modules')
  })

  it('renders the warning text from <warning>...</warning>', () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope() })

    // The header's right-hand side shows the warning body, styled orange.
    // Locks in that <warning>no matches for pattern "X" in path "Y"</warning>
    // surfaces the actionable message ("no matches for pattern...") so
    // the operator can copy/paste it into a chat.
    const html = wrapper.html()
    expect(html).toContain('no matches for pattern')
    expect(html).toContain('needle_NOT_FOUND')
    expect(html).toContain('/tmp/repo/src')
  })

  it('falls back to "unknown" only when the envelope truly has no pattern attribute', () => {
    // Pre-fix wire shape — no <search pattern="..."> wrapper. We keep
    // the "unknown" fallback for back-compat with stale DB rows or
    // migration lag. The fix's job is to ensure NEW results carry the
    // wrapper; this test confirms we haven't broken the fallback.
    const wrapper = makeWrapper({
      content: '<warning>pattern not found</warning>',
    })

    expect(wrapper.html()).toContain('unknown')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Match-found envelope — must still work after the no-match fix
// ────────────────────────────────────────────────────────────────────────

describe('Search.vue — match-found envelope (regression guard)', () => {
  it('renders the pattern + path on match results', () => {
    const wrapper = makeWrapper({
      content: oneMatchEnvelope('TODO', '/repo/src'),
    })

    expect(wrapper.html()).toContain('TODO')
    expect(wrapper.html()).toContain('/repo/src')
  })

  it('does NOT render the "unknown" fallback when envelope has the wrapper', () => {
    const wrapper = makeWrapper({
      content: oneMatchEnvelope('TODO', '/repo/src'),
    })

    const html = wrapper.html()
    expect(html).not.toContain('"unknown"')
    expect(html).not.toContain('in unknown')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Empty/no-match results — Arguments must still be reachable.
//
// Bug: the expanded body was `v-if="isExpanded && fileResults.length > 0"`
// and toggle() refused to expand on a warning/empty envelope, so a no-match
// search (warning envelope) could never show its Arguments block.
// ────────────────────────────────────────────────────────────────────────

describe('Search.vue — warning envelope still shows Arguments (empty/no-match)', () => {
  const warningContent =
    `<search pattern="foo" path="/tmp">\n` +
    `<warning>no matches for pattern</warning>\n` +
    `</search>\n`
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

// ────────────────────────────────────────────────────────────────────────
// Output contract (backend change 2026-09-16, search.zig):
//   * every interpolated value (pattern, path, file path, snippet, warning)
//     is XML-escaped on the wire,
//   * <search> carries returned/total/truncated.
// The card must decode the escapes for display and surface truncation —
// an escaped `&lt;file …&gt;` inside a snippet must NOT become a file row,
// and a capped search must not look exhaustive.
// ────────────────────────────────────────────────────────────────────────

const envelopeWithSummary = (
  file: { path: string; total: number; count: number; lines: Array<{ l: number; s: string }> },
  summary: { returned: number; total: number; truncated: boolean },
  pattern = 'foo',
  path = '/tmp/repo',
) =>
  `<search pattern="${pattern}" path="${path}" returned="${summary.returned}" total="${summary.total}" truncated="${summary.truncated}">\n` +
  (summary.truncated
    ? `  <truncated>${summary.returned} of ${summary.total} matched lines shown — raise max_results.</truncated>\n`
    : '') +
  `  <file path="${file.path}" total="${file.total}" count="${file.count}">\n` +
  file.lines.map((m) => `    <m><l>${m.l}</l><s>${m.s}</s></m>\n`).join('') +
  `  </file>\n` +
  `</search>\n`

describe('Search.vue — XML-escaped payload is decoded for display', () => {
  it('decodes escaped snippets back to source text when expanded', () => {
    const wrapper = makeWrapper({
      content: envelopeWithSummary(
        {
          path: '/tmp/repo/a.vue',
          total: 1,
          count: 1,
          lines: [{ l: 3, s: '&lt;div&gt;hi&lt;/div&gt; &amp; more' }],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    const text = wrapper.text()
    expect(text).toContain('<div>hi</div> & more')
    expect(text).not.toContain('&lt;div&gt;')
  })

  it('decodes an escaped file path', () => {
    const wrapper = makeWrapper({
      content: envelopeWithSummary(
        { path: '/tmp/a&amp;b.txt', total: 1, count: 1, lines: [{ l: 1, s: 'foo' }] },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    expect(wrapper.text()).toContain('/tmp/a&b.txt')
  })

  it('does not treat an escaped <file …> inside a snippet as a real file row', () => {
    const wrapper = makeWrapper({
      content: envelopeWithSummary(
        {
          path: '/tmp/repo/hostile.txt',
          total: 1,
          count: 1,
          lines: [
            { l: 2, s: '&lt;file path=&quot;x&quot; total=&quot;1&quot; count=&quot;1&quot;&gt;' },
          ],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    // Exactly one real file parsed; the snippet's look-alike header is text.
    expect(wrapper.text()).toContain('1 file,')
    expect(wrapper.text()).toContain('<file path="x" total="1" count="1">')
  })

  it('decodes an escaped pattern attribute', () => {
    const wrapper = makeWrapper({ content: noMatchEnvelope('a&quot;b', '/tmp') })

    expect(wrapper.text()).toContain('a"b')
  })

  it('decodes an escaped warning body', () => {
    const wrapper = makeWrapper({
      content:
        `<search pattern="x" path="/y">\n` +
        `<warning>no matches for pattern "&lt;div&gt;" in path "/y"</warning>\n` +
        `</search>\n`,
    })

    expect(wrapper.text()).toContain('no matches for pattern "<div>" in path "/y"')
  })
})

describe('Search.vue — truncation summary from <search returned/total/truncated>', () => {
  it('shows "N of M matches (truncated)" when the backend capped the result', () => {
    const wrapper = makeWrapper({
      content: envelopeWithSummary(
        {
          path: '/tmp/repo/a.ts',
          total: 2,
          count: 2,
          lines: [
            { l: 1, s: 'foo' },
            { l: 2, s: 'foo' },
          ],
        },
        { returned: 2, total: 40, truncated: true },
      ),
    })

    const badge = wrapper.find('[data-testid="search-truncated"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('2 of 40 matches (truncated)')
  })

  it('keeps the plain wording when truncated=false', () => {
    const wrapper = makeWrapper({
      content: envelopeWithSummary(
        { path: '/tmp/repo/a.ts', total: 1, count: 1, lines: [{ l: 1, s: 'foo' }] },
        { returned: 1, total: 1, truncated: false },
      ),
    })

    expect(wrapper.text()).toContain('1 file, 1 match')
    expect(wrapper.find('[data-testid="search-truncated"]').exists()).toBe(false)
  })

  it('keeps the plain wording for legacy envelopes without summary attrs', () => {
    const wrapper = makeWrapper({ content: oneMatchEnvelope('TODO', '/repo/src') })

    expect(wrapper.text()).toContain('1 file, 1 match')
    expect(wrapper.find('[data-testid="search-truncated"]').exists()).toBe(false)
  })
})
