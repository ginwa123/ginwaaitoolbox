import { describe, expect, it } from 'vitest'

import {
  SEARCH_URL_TEMPLATE,
  browserTabTitle,
  hostOf,
  isHttpUrl,
  normalizeAddressInput,
} from '../helpers/browserUrl'

/** The refusal reason of a rejected address, or `''` when it was accepted. */
function reasonOf(result: ReturnType<typeof normalizeAddressInput>): string {
  return result.ok ? '' : result.reason
}

describe('normalizeAddressInput', () => {
  it('passes absolute http/https through untouched', () => {
    expect(normalizeAddressInput('https://example.com/a/b?x=1')).toEqual({
      ok: true,
      url: 'https://example.com/a/b?x=1',
    })
    expect(normalizeAddressInput('http://localhost:5173/')).toEqual({
      ok: true,
      url: 'http://localhost:5173/',
    })
  })

  it('gives a bare host an https:// scheme', () => {
    expect(normalizeAddressInput('example.com')).toEqual({ ok: true, url: 'https://example.com' })
    expect(normalizeAddressInput('example.com/a/b?x=1')).toEqual({
      ok: true,
      url: 'https://example.com/a/b?x=1',
    })
    expect(normalizeAddressInput('localhost:5173')).toEqual({
      ok: true,
      url: 'https://localhost:5173',
    })
    expect(normalizeAddressInput('localhost')).toEqual({ ok: true, url: 'https://localhost' })
  })

  it('turns anything else into a Google search', () => {
    expect(normalizeAddressInput('zig lang')).toEqual({
      ok: true,
      url: SEARCH_URL_TEMPLATE + encodeURIComponent('zig lang'),
    })
  })

  it('refuses non-http schemes with a reason and never searches them', () => {
    for (const raw of [
      'javascript:alert(1)',
      'file:///etc/passwd',
      'data:text/html,x',
      'about:blank',
    ]) {
      const r = normalizeAddressInput(raw)
      // The whole union, so the discriminant AND the reason are asserted —
      // no `expect` inside a narrowing `if` (eslint no-conditional-expect).
      expect(r.ok).toBe(false)
      expect(reasonOf(r)).toContain('not allowed here')
    }
    expect(normalizeAddressInput('javascript:alert(1)')).toEqual({
      ok: false,
      reason: 'javascript: URLs are not allowed here',
    })
  })

  it('asks for input on empty strings', () => {
    expect(normalizeAddressInput('')).toEqual({
      ok: false,
      reason: 'Enter an address or a search term',
    })
    expect(normalizeAddressInput('   ')).toEqual({
      ok: false,
      reason: 'Enter an address or a search term',
    })
  })

  it('trims before deciding', () => {
    expect(normalizeAddressInput('  example.com  ')).toEqual({
      ok: true,
      url: 'https://example.com',
    })
  })
})

describe('isHttpUrl', () => {
  it('accepts http/https and rejects everything else', () => {
    expect(isHttpUrl('https://example.com')).toBe(true)
    expect(isHttpUrl('http://localhost:5173/x')).toBe(true)
    expect(isHttpUrl('example.com')).toBe(false)
    expect(isHttpUrl('javascript:alert(1)')).toBe(false)
    expect(isHttpUrl('blob:https://example.com/x')).toBe(false)
    expect(isHttpUrl('')).toBe(false)
  })
})

describe('hostOf', () => {
  it('keeps the port and returns empty for garbage', () => {
    expect(hostOf('https://github.com/x')).toBe('github.com')
    expect(hostOf('http://localhost:5173/x')).toBe('localhost:5173')
    expect(hostOf('not a url')).toBe('')
    expect(hostOf('')).toBe('')
  })
})

describe('browserTabTitle', () => {
  it('shows the host, falling back to New tab', () => {
    expect(browserTabTitle('https://github.com/x')).toBe('github.com')
    expect(browserTabTitle(undefined)).toBe('New tab')
    expect(browserTabTitle(null)).toBe('New tab')
    expect(browserTabTitle('')).toBe('New tab')
    expect(browserTabTitle('not a url')).toBe('New tab')
  })
})
