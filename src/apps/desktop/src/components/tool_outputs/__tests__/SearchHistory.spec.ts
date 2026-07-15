/**
 * Tests for SearchHistory.vue.
 *
 * Verifies:
 *  - dispatches correctly between mode="text" / mode="session" / error envelopes
 *  - header summary text reflects mode, query/session, and count/total_count
 *  - "N of M" badge appears only when total_count > count (paginated)
 *  - text-mode entries render id, role badge, session_id, snippet with [match] highlighting
 *  - session-mode entries render id, role badge, preview, and full content toggle
 *    when present (with the truncated attr surfaced as a "(truncated)" label)
 *  - error envelope renders the error text in red, hides entries
 *  - empty result renders the "No matches for ..." / "No messages in ..." hint
 *  - click on header toggles expanded state (only when there are entries or an error)
 *  - copy-id buttons copy the message id to clipboard
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import SearchHistory from '../SearchHistory.vue'

// ────────────────────────────────────────────────────────────────────────
// Test helpers
// ────────────────────────────────────────────────────────────────────────

const makeTextContent = (opts: {
  query?: string
  offset?: number
  limit?: number
  count?: number
  total_count?: number
  entries?: Array<{ id: string; session_id?: string; role?: string; created_at?: string; snippet?: string }>
} = {}) => {
  const query = opts.query ?? 'login bug'
  const offset = opts.offset ?? 0
  const limit = opts.limit ?? 20
  const count = opts.count ?? opts.entries?.length ?? 0
  const total = opts.total_count ?? count
  const entries = opts.entries ?? []
  const entryXml = entries
    .map((e) => {
      const id = e.id
      const sid = e.session_id ?? 's_default'
      const role = e.role ?? 'user'
      const ca = e.created_at ?? '2026-01-01 10:00:00'
      const snip = e.snippet ?? '...the login [match]bug[/match] needs fixing...'
      return [
        '    <entry>',
        `      <id>${id}</id>`,
        `      <session_id>${sid}</session_id>`,
        `      <role>${role}</role>`,
        `      <created_at>${ca}</created_at>`,
        `      <snippet>${snip}</snippet>`,
        '    </entry>',
      ].join('\n')
    })
    .join('\n')
  return [
    `<search_history mode="text" offset="${offset}" limit="${limit}">`,
    `  <query>${query}</query>`,
    `  <count>${count}</count>`,
    `  <total_count>${total}</total_count>`,
    `  <results>`,
    entryXml,
    `  </results>`,
    `</search_history>`,
  ].join('\n')
}

const makeSessionContent = (opts: {
  session_id?: string
  order?: 'asc' | 'desc'
  count?: number
  total_count?: number
  entries?: Array<{
    id: string
    role?: string
    created_at?: string
    preview?: string
    tool_call_id?: string
    tool_name?: string
    content?: string
    content_truncated?: boolean
  }>
} = {}) => {
  const sid = opts.session_id ?? 's_X'
  const order = opts.order ?? 'asc'
  const count = opts.count ?? opts.entries?.length ?? 0
  const total = opts.total_count ?? count
  const entries = opts.entries ?? []
  const entryXml = entries
    .map((e) => {
      const role = e.role ?? 'user'
      const ca = e.created_at ?? '2026-01-01 10:00:00'
      const preview = e.preview ?? 'short preview'
      const parts = [
        '    <entry>',
        `      <id>${e.id}</id>`,
        `      <role>${role}</role>`,
        `      <created_at>${ca}</created_at>`,
        `      <preview>${preview}</preview>`,
      ]
      if (e.tool_call_id) parts.push(`      <tool_call_id>${e.tool_call_id}</tool_call_id>`)
      if (e.tool_name) parts.push(`      <tool_name>${e.tool_name}</tool_name>`)
      if (e.content !== undefined) {
        const trunc = e.content_truncated ? ' truncated="1"' : ' truncated="0"'
        parts.push(`      <content${trunc}>${e.content}</content>`)
      }
      parts.push('    </entry>')
      return parts.join('\n')
    })
    .join('\n')
  return [
    `<search_history mode="session" order="${order}">`,
    `  <session_id>${sid}</session_id>`,
    `  <count>${count}</count>`,
    `  <total_count>${total}</total_count>`,
    `  <message_index>`,
    entryXml,
    `  </message_index>`,
    `</search_history>`,
  ].join('\n')
}

const makeErrorContent = (msg = 'Database query failed: SyntaxError') =>
  `<search_history><error>${msg}</error></search_history>`

// ────────────────────────────────────────────────────────────────────────
// jsdom doesn't ship a clipboard by default; provide a minimal stub.
// ────────────────────────────────────────────────────────────────────────

let clipboardWrites: string[] = []

beforeEach(() => {
  clipboardWrites = []
  // jsdom doesn't define navigator.clipboard; attach a minimal stub.
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: vi.fn(async (s: string) => { clipboardWrites.push(s) }) },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('SearchHistory.vue — envelope dispatch', () => {
  it('renders mode="text" header with query + entry count', () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeTextContent({ entries: [{ id: 'h1', snippet: '[match]login bug[/match]' }] }) },
    })
    expect(wrapper.find('[data-testid="search-history"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('search_history')
    expect(wrapper.text()).toContain('text search')
    expect(wrapper.text()).toContain('"login bug"')
    expect(wrapper.text()).toContain('1 entry')
  })

  it('renders mode="session" header with session_id + order', () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeSessionContent({ session_id: 's_long', order: 'desc', entries: [{ id: 'h1' }] }) },
    })
    expect(wrapper.text()).toContain('session')
    expect(wrapper.text()).toContain('s_long')
    expect(wrapper.text()).toContain('order=desc')
  })

  it('renders error envelope with red border + error text', () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeErrorContent('Mode "bogus" not recognized') },
    })
    expect(wrapper.find('[data-testid="search-history"]').classes()).toContain('border-red-500/50')
    expect(wrapper.find('[data-testid="search-history-error"]').text()).toContain('Mode "bogus" not recognized')
    // No entry list rendered.
    expect(wrapper.find('[data-testid="search-history-text-entries"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="search-history-session-entries"]').exists()).toBe(false)
  })
})

describe('SearchHistory.vue — pagination badge', () => {
  it('shows "N of M" badge only when total_count > count (paginated)', () => {
    // Paginated: 2 of 5 returned
    const paginated = mount(SearchHistory, {
      props: { content: makeTextContent({ count: 2, total_count: 5, entries: [{ id: 'h1' }, { id: 'h2' }] }) },
    })
    const badge = paginated.find('[data-testid="search-history-page-badge"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toBe('2 of 5')

    // Not paginated: all 5 fit in one page — no badge
    const full = mount(SearchHistory, {
      props: { content: makeTextContent({ count: 5, total_count: 5, entries: [{ id: 'h1' }, { id: 'h2' }, { id: 'h3' }, { id: 'h4' }, { id: 'h5' }] }) },
    })
    expect(full.find('[data-testid="search-history-page-badge"]').exists()).toBe(false)
    expect(full.text()).toContain('5 entries')
  })
})

describe('SearchHistory.vue — mode="text" entries', () => {
  it('renders one <li> per entry with role badge, id, session_id, snippet', () => {
    const wrapper = mount(SearchHistory, {
      props: {
        expanded: true,
        content: makeTextContent({
          entries: [
            { id: 'h1', role: 'user', session_id: 's_42', snippet: 'fix [match]login bug[/match]' },
            { id: 'h2', role: 'assistant', session_id: 's_42', snippet: '[match]login[/match] confirmed' },
          ],
        }),
      },
    })
    const entries = wrapper.findAll('[data-testid="search-history-text-entry"]')
    expect(entries.length).toBe(2)

    expect(entries[0]!.text()).toContain('user')
    expect(entries[0]!.text()).toContain('h1')
    expect(entries[0]!.text()).toContain('s_42')
    expect(entries[0]!.text()).toContain('login bug')
  })

  it('highlights [match]...[/match] spans inside the snippet with <mark>', () => {
    const wrapper = mount(SearchHistory, {
      props: { expanded: true, content: makeTextContent({ entries: [{ id: 'h1', snippet: 'pre [match]login bug[/match] post' }] }) },
    })
    // The wrapper uses raw search-text as part of the entry; verify
    // that at least one <mark> exists with the matched text.
    const snippetEl = wrapper.find('[data-testid="text-entry-snippet-0"]')
    expect(snippetEl.exists()).toBe(true)
    expect(snippetEl.html()).toContain('<mark')
    expect(snippetEl.html()).toContain('login bug')
    expect(snippetEl.html()).toContain('pre')
    expect(snippetEl.html()).toContain('post')
  })

  it('renders the empty-results hint when text query matches nothing', () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeTextContent({ query: 'no-such-string', count: 0, total_count: 0, entries: [] }) },
    })
    expect(wrapper.find('[data-testid="search-history-empty"]').text()).toContain('No matches for "no-such-string"')
    expect(wrapper.find('[data-testid="search-history-text-entries"]').exists()).toBe(false)
  })
})

describe('SearchHistory.vue — mode="session" entries', () => {
  it('renders role badge, id, preview, and tool_call_id/tool_name for tool-role entries', () => {
    const wrapper = mount(SearchHistory, {
      props: {
        expanded: true,
        content: makeSessionContent({
          entries: [
            { id: 'h_user', role: 'user', preview: 'fix the login bug' },
            { id: 'h_tool', role: 'tool', preview: 'bash output', tool_call_id: 'call_123', tool_name: 'bash' },
          ],
        }),
      },
    })
    const entries = wrapper.findAll('[data-testid="search-history-session-entry"]')
    expect(entries.length).toBe(2)
    expect(entries[1]!.text()).toContain('tool')
    expect(entries[1]!.text()).toContain('call_123')
    expect(entries[1]!.text()).toContain('bash')
  })

  it('hides the full <content> by default; toggle button expands it', async () => {
    const wrapper = mount(SearchHistory, {
      props: { expanded: true, content: makeSessionContent({ entries: [{ id: 'h_full', role: 'assistant', content: 'this is the full body', content_truncated: false }] }) },
    })
    // Content body should be hidden initially.
    expect(wrapper.find('[data-testid="session-entry-content-0"]').exists()).toBe(false)
    // Click the toggle.
    await wrapper.find('[data-testid="session-entry-toggle-content-0"]').trigger('click')
    expect(wrapper.find('[data-testid="session-entry-content-0"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="session-entry-content-0"]').text()).toBe('this is the full body')
  })

  it('shows "(truncated)" label when content_truncated is true', async () => {
    const wrapper = mount(SearchHistory, {
      props: { expanded: true, content: makeSessionContent({ entries: [{ id: 'h_full', role: 'assistant', content: 'first 16 KB...', content_truncated: true }] }) },
    })
    const toggle = wrapper.find('[data-testid="session-entry-toggle-content-0"]')
    expect(toggle.exists()).toBe(true)
    expect(toggle.text()).toContain('(truncated)')
  })

  it('renders the empty-results hint when session has 0 messages', () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeSessionContent({ session_id: 's_empty', count: 0, total_count: 0, entries: [] }) },
    })
    expect(wrapper.find('[data-testid="search-history-empty"]').text()).toContain('No messages in s_empty')
    expect(wrapper.find('[data-testid="search-history-session-entries"]').exists()).toBe(false)
  })
})

describe('SearchHistory.vue — interactions', () => {
  it('clicking the header toggles expanded state when entries are present', async () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeTextContent({ entries: [{ id: 'h1' }] }) },
    })
    // Collapsed by default; toggle the header to expand.
    expect(wrapper.find('[data-testid="search-history-text-entries"]').exists()).toBe(false)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="search-history-text-entries"]').exists()).toBe(true)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="search-history-text-entries"]').exists()).toBe(false)
  })

  it('starts in expanded state when `expanded` prop is true', () => {
    const wrapper = mount(SearchHistory, {
      props: { content: makeTextContent({ entries: [{ id: 'h1' }] }), expanded: true },
    })
    expect(wrapper.find('[data-testid="search-history-text-entries"]').exists()).toBe(true)
  })

  it('copy-id button writes the message id to the clipboard', async () => {
    const wrapper = mount(SearchHistory, {
      props: { expanded: true, content: makeSessionContent({ entries: [{ id: 'h_42_unique' }] }) },
    })
    await wrapper.find('.copy-btn').trigger('click')
    expect(clipboardWrites).toContain('h_42_unique')
  })
})