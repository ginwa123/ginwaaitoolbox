/**
 * Tests for helpers/codeHighlight.ts.
 *
 * Verifies:
 *  - detectLanguage maps extensions to monaco ids (matches CodeEditor's
 *    old inline table) and falls back to plaintext
 *  - highlightLine tokenizes keywords/strings/comments/numbers/functions/
 *    types per language, keeps `#`/`//` inside strings as strings, and
 *    passes plaintext through as a single plain token
 */
import { describe, expect, it } from 'vitest'

import { detectLanguage, highlightLine } from './codeHighlight'

describe('detectLanguage', () => {
  it('maps common extensions', () => {
    expect(detectLanguage('foo.ts')).toBe('typescript')
    expect(detectLanguage('foo.tsx')).toBe('typescript')
    expect(detectLanguage('foo.js')).toBe('javascript')
    expect(detectLanguage('foo.vue')).toBe('html')
    expect(detectLanguage('foo.py')).toBe('python')
    expect(detectLanguage('foo.zig')).toBe('zig')
    expect(detectLanguage('foo.rs')).toBe('rust')
    expect(detectLanguage('run.sh')).toBe('shell')
    expect(detectLanguage('a.toml')).toBe('ini')
  })

  it('is case-insensitive and falls back to plaintext', () => {
    expect(detectLanguage('FOO.TS')).toBe('typescript')
    expect(detectLanguage('notes.log')).toBe('plaintext')
    expect(detectLanguage('no-extension')).toBe('plaintext')
    expect(detectLanguage('file.unknownext')).toBe('plaintext')
    expect(detectLanguage('')).toBe('plaintext')
  })
})

describe('highlightLine', () => {
  it('passes plaintext through as a single plain token', () => {
    expect(highlightLine('const x = "hi" // c', 'plaintext')).toEqual([
      { text: 'const x = "hi" // c', type: 'plain' },
    ])
  })

  it('tokenizes typescript keywords, strings, comments, numbers', () => {
    const tokens = highlightLine('const name = "ada"; // greeting', 'typescript')
    expect(tokens).toContainEqual({ text: 'const', type: 'keyword' })
    expect(tokens).toContainEqual({ text: '"ada"', type: 'string' })
    expect(tokens).toContainEqual({ text: '// greeting', type: 'comment' })
    const nums = highlightLine('const n = 42', 'typescript')
    expect(nums).toContainEqual({ text: '42', type: 'number' })
  })

  it('detects function calls and types', () => {
    const tokens = highlightLine('const r = parseTextReplace(data)', 'typescript')
    expect(tokens).toContainEqual({ text: 'parseTextReplace', type: 'function' })
    const types = highlightLine('const w: TextReplaceResult = x', 'typescript')
    expect(types).toContainEqual({ text: 'TextReplaceResult', type: 'type' })
  })

  it('keeps comment markers inside strings as strings (zig)', () => {
    const tokens = highlightLine('const s = "a // b"; // real', 'zig')
    expect(tokens).toContainEqual({ text: '"a // b"', type: 'string' })
    expect(tokens).toContainEqual({ text: '// real', type: 'comment' })
  })

  it('handles python # comments and keywords', () => {
    const tokens = highlightLine('def foo():  # define', 'python')
    expect(tokens).toContainEqual({ text: 'def', type: 'keyword' })
    expect(tokens).toContainEqual({ text: 'foo', type: 'function' })
    expect(tokens).toContainEqual({ text: '# define', type: 'comment' })
  })

  it('handles shell # comments', () => {
    const tokens = highlightLine('echo hi # done', 'shell')
    expect(tokens).toContainEqual({ text: '# done', type: 'comment' })
  })

  it('handles html comments', () => {
    const tokens = highlightLine('<div><!-- note --></div>', 'html')
    expect(tokens).toContainEqual({ text: '<!-- note -->', type: 'comment' })
  })

  it('returns plain for empty lines', () => {
    expect(highlightLine('', 'typescript')).toEqual([{ text: '', type: 'plain' }])
  })

  it('escapes nothing itself — returns raw text (Vue text nodes escape)', () => {
    const tokens = highlightLine('<script>alert(1)</script>', 'typescript')
    expect(tokens.map((t) => t.text).join('')).toBe('<script>alert(1)</script>')
  })
})
