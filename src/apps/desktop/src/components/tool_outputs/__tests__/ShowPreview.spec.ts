/**
 * Tests for ShowPreview.vue — the tool-output card component for the
 * `show_preview` agent tool. The card always renders inline (no side
 * panel): success path renders tool name + title (or content_type) +
 * human-friendly content_length + ✓ badge plus the rich content;
 * error path renders ✗ + error message inline.
 */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import ShowPreview from '../ShowPreview.vue'

beforeEach(() => {})

// ────────────────────────────────────────────────────────────────────────
// Test helpers
// ────────────────────────────────────────────────────────────────────────

const makeSuccessContent = (opts: {
  previewId?: string
  contentType?: string
  contentLength?: number
} = {}) => {
  const previewId = opts.previewId ?? 'pv_1783698705145_1cae92'
  const contentType = opts.contentType ?? 'markdown'
  const contentLength = opts.contentLength ?? 1234
  return [
    '<show_preview>',
    '<status>shown</status>',
    `<preview_id>${previewId}</preview_id>`,
    `<content_type>${contentType}</content_type>`,
    `<content_length>${contentLength}</content_length>`,
    '</show_preview>',
  ].join('\n')
}

const makeErrorContent = (errorMsg = 'invalid content_type "foo"') => {
  return [
    '<show_preview>',
    `<error>${errorMsg}</error>`,
    '</show_preview>',
  ].join('\n')
}

const makeParameters = (opts: {
  title?: string
  contentType?: string
} = {}) => {
  return JSON.stringify({
    content_type: opts.contentType ?? 'markdown',
    content: '# Hello',
    title: opts.title,
  })
}

const makeWrapper = (
  opts: {
    content?: string
    messageId?: string
    parameters?: string
  } = {},
) => {
  return mount(ShowPreview, {
    props: {
      content: opts.content ?? makeSuccessContent(),
      messageId: opts.messageId ?? 'msg_test_1',
      parameters: opts.parameters ?? '{}',
    },
  })
}

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────

describe('ShowPreview', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  // ─── data-testid + basic structure ─────────────────────────────────

  it('renders the card with a data-testid based on the message id', () => {
    wrapper = makeWrapper({ messageId: 'msg_abc_123' })
    const card = wrapper.find('[data-testid="show-preview-card-msg_abc_123"]')
    expect(card.exists()).toBe(true)
    // Inline-only: the card is not a button (no side panel to open).
    expect(card.attributes('role')).toBeUndefined()
  })

  // ─── success path ──────────────────────────────────────────────────

  it('renders success: tool name + content_type + size + ✓ badge', () => {
    wrapper = makeWrapper({
      content: makeSuccessContent({ contentType: 'markdown', contentLength: 1234 }),
    })
    const text = wrapper.text()
    // Tool name in violet pill.
    expect(text).toContain('show_preview')
    // Content type shown as primary label when no title.
    expect(text).toContain('markdown')
    // content_length formatted as KB (1234 bytes ≈ 1.2 KB).
    expect(text).toContain('1.2 KB')
    // Status badge.
    expect(text).toContain('✓')
    expect(text).not.toContain('✗')
  })

  it('prefers the parameter title over the content_type as primary label', () => {
    wrapper = makeWrapper({
      content: makeSuccessContent({ contentType: 'markdown' }),
      parameters: makeParameters({ title: 'My Cool Plan', contentType: 'markdown' }),
    })
    const text = wrapper.text()
    // Title is the primary label.
    expect(text).toContain('My Cool Plan')
    // When title is shown, content_type moves to the right-meta.
    expect(text).toContain('markdown')
    // ✓ status still present.
    expect(text).toContain('✓')
  })

  it('formats bytes: < 1024 as B, < 1MB as KB, ≥ 1MB as MB', () => {
    const bytesCases = [
      { n: 500, expect: '500 B' },
      { n: 2048, expect: '2.0 KB' },
      { n: 5 * 1024 * 1024, expect: '5.00 MB' },
    ]
    for (const { n, expect: expectedStr } of bytesCases) {
      wrapper?.unmount()
      wrapper = makeWrapper({ content: makeSuccessContent({ contentLength: n }) })
      expect(wrapper.text()).toContain(expectedStr)
    }
  })

  // ─── error path ────────────────────────────────────────────────────

  it('renders error: ✗ badge + error message inline', () => {
    wrapper = makeWrapper({
      content: makeErrorContent('invalid content_type "foo". Must be one of: "markdown", "text", "code", "image".'),
    })
    const text = wrapper.text()
    // ✗ badge instead of ✓.
    expect(text).toContain('✗')
    expect(text).not.toContain('✓')
    // The full error message is visible inline (no need to expand).
    expect(text).toContain('invalid content_type')
    expect(text).toContain('Error:')
    // The error card has the red border class.
    const card = wrapper.find('[data-testid="show-preview-card-msg_test_1"]')
    expect(card.classes().join(' ')).toContain('border-red-500/50')
  })

  // ─── no side panel: card never emits `open` ────────────────────────

  it('does NOT emit `open` when the card is clicked (inline-only)', async () => {
    wrapper = makeWrapper({ messageId: 'msg_click_target' })
    await wrapper.find('[data-testid="show-preview-card-msg_click_target"]').trigger('click')
    expect(wrapper.emitted('open')).toBeFalsy()
  })

  it('copy-preview-id button does not emit `open`', async () => {
    wrapper = makeWrapper({ messageId: 'msg_copy_1' })
    const buttons = wrapper.findAll('button')
    expect(buttons.length).toBeGreaterThanOrEqual(1)
    await buttons[0]!.trigger('click')
    expect(wrapper.emitted('open')).toBeFalsy()
  })

  // ─── parameters fallback ───────────────────────────────────────────

  it('falls back gracefully when parameters is invalid JSON', () => {
    // No throw, no crash. The card still renders.
    wrapper = makeWrapper({ parameters: '{not valid json' })
    const text = wrapper.text()
    expect(text).toContain('show_preview')
    expect(text).toContain('✓')
    // Falls back to content_type from the envelope (markdown).
    expect(text).toContain('markdown')
  })

  it('falls back to content_type from the envelope when parameters has no title', () => {
    wrapper = makeWrapper({
      content: makeSuccessContent({ contentType: 'text' }),
      parameters: JSON.stringify({ content_type: 'text', content: 'hello' }), // no title
    })
    // Content type is the primary label when title is absent.
    expect(wrapper.text()).toContain('text')
  })
})