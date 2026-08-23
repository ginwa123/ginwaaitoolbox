/**
 * Unit tests for the <html> wrapper-tag helpers in stripTags.ts.
 *
 * Plan: docs/superpowers/plans/2026-08-23-html-tag-support.md (Task 2)
 *
 * The <html> tag lets the LLM emit raw HTML that the chat UI renders
 * as a live sandboxed-iframe block. These tests lock in:
 *   - getHtmlTags: extract inner payload(s) of <html>...</html>
 *   - isHtmlTags: true when content is ONLY html blocks (+ optional think)
 *   - stripThinkingTags: unwraps <html> like <plain>/<markdown>, drops
 *     <think> when a sibling wrapper exists, keeps visibility non-empty
 */
import { describe, expect, it } from 'vitest'
import { getHtmlTags, isHtmlTags, stripThinkingTags } from '../helpers/stripTags'

describe('getHtmlTags', () => {
  it('extracts inner content of a single block', () => {
    expect(getHtmlTags('<html><div>x</div></html>')).toBe('<div>x</div>')
  })

  it('extracts multiple blocks joined with blank line', () => {
    const got = getHtmlTags('<html><b>a</b></html> mid <html><i>b</i></html>')
    expect(got).toBe('<b>a</b>\n\n<i>b</i>')
  })

  it('returns empty string when no html tag present', () => {
    expect(getHtmlTags('plain text')).toBe('')
    expect(getHtmlTags('')).toBe('')
  })

  it('is case-insensitive on the tag name', () => {
    expect(getHtmlTags('<HTML><div>x</div></HTML>')).toBe('<div>x</div>')
  })
})

describe('isHtmlTags', () => {
  it('true for html-only content', () => {
    expect(isHtmlTags('<html>a</html>')).toBe(true)
  })

  it('true for think + html mix (think is not visible content)', () => {
    expect(isHtmlTags('<think>t</think><html>a</html>')).toBe(true)
  })

  it('false for plain text', () => {
    expect(isHtmlTags('just text')).toBe(false)
  })

  it('false when html is only part of the content', () => {
    expect(isHtmlTags('before <html>a</html> after')).toBe(false)
  })

  it('false for empty/undefined-ish input', () => {
    expect(isHtmlTags('')).toBe(false)
  })
})

describe('stripThinkingTags — <html> interplay', () => {
  it('unwraps a lone html block to its inner content', () => {
    expect(stripThinkingTags('<html>a</html>')).toBe('a')
  })

  it('drops think and unwraps html when both present', () => {
    expect(stripThinkingTags('<think>s</think><html><b>hi</b></html>')).toBe(
      '<b>hi</b>',
    )
  })

  it('keeps html-only messages VISIBLE (non-empty result)', () => {
    // Visibility filtering (ChatView filteredMessages / hasVisibleContent)
    // relies on stripThinkingTags(...).trim().length > 0.
    const stripped = stripThinkingTags('<html><h1>Title</h1></html>')
    expect(stripped.length).toBeGreaterThan(0)
    expect(stripped).toContain('<h1>')
  })

  it('leaves content without tags unchanged', () => {
    expect(stripThinkingTags('no tags here')).toBe('no tags here')
  })

  it('does not leak raw <think> into marked for think+html messages', () => {
    const stripped = stripThinkingTags('<think>secret</think><html>x</html>')
    expect(stripped).not.toContain('<think>')
    expect(stripped).not.toContain('secret')
  })

  it('preserves lone-think passthrough behavior (regression guard)', () => {
    // Existing contract: lone <think> is returned unchanged by design
    // (rendered as a thinking bubble, not markdown).
    expect(stripThinkingTags('<think>reasoning only</think>')).toBe(
      '<think>reasoning only</think>',
    )
  })
})
