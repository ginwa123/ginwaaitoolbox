/**
 * Pure URL helpers for the in-app browser tab.
 *
 * No imports from `tabTarget` — that module imports `browserTabTitle` from
 * here, so importing back would be a cycle.
 */

export const SEARCH_URL_TEMPLATE = 'https://www.google.com/search?q='

export type AddressResult = { ok: true; url: string } | { ok: false; reason: string }

const SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:/

/**
 * Is this really `<scheme>:…`, or a bare `host:port`?
 *
 * `localhost:5173` and `example.com:8080` match the scheme shape, but a
 * `:` followed by a numeric port is a host, not a scheme — treating it as
 * one would refuse a dev-server address the user can plainly see.
 */
function looksLikeScheme(raw: string): boolean {
  const match = SCHEME_RE.exec(raw)
  if (!match) return false
  if (match[0].slice(0, -1).toLowerCase() === 'localhost') return false
  const rest = raw.slice(match[0].length)
  return !/^\d+([/?#]|$)/.test(rest)
}

export function isHttpUrl(raw: string): boolean {
  const trimmed = raw.trim()
  if (!looksLikeScheme(trimmed)) return false
  try {
    const parsed = new URL(trimmed)
    return parsed.protocol === 'http:' || parsed.protocol === 'https:'
  } catch {
    return false
  }
}

function schemeOf(raw: string): string {
  const match = SCHEME_RE.exec(raw)
  if (!match) return ''
  return match[0].slice(0, -1).toLowerCase()
}

/**
 * Normalize what the user typed in the address bar.
 *
 * - Empty → a reason (nothing to open).
 * - An explicit scheme: http/https passes through; ANY other scheme
 *   (`javascript:`, `data:`, `file:`, `about:`, …) is refused with a reason
 *   and is never turned into a search.
 * - No scheme: a bare host (`localhost`, `localhost:5173`, `example.com`,
 *   `example.com/a/b?x=1`) gains `https://`; anything else is a Google search.
 */
export function normalizeAddressInput(raw: string): AddressResult {
  const trimmed = raw.trim()
  if (trimmed === '') return { ok: false, reason: 'Enter an address or a search term' }
  if (looksLikeScheme(trimmed)) {
    if (isHttpUrl(trimmed)) return { ok: true, url: trimmed }
    const scheme = schemeOf(trimmed)
    return { ok: false, reason: `${scheme}: URLs are not allowed here` }
  }
  const beforeSlash = trimmed.split('/')[0] ?? ''
  if (
    beforeSlash === 'localhost' ||
    beforeSlash.startsWith('localhost:') ||
    beforeSlash.includes('.')
  ) {
    return { ok: true, url: `https://${trimmed}` }
  }
  return { ok: true, url: SEARCH_URL_TEMPLATE + encodeURIComponent(trimmed) }
}

/** Host (with port) of an absolute URL, or `''` when it does not parse. */
export function hostOf(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return ''
  }
}

/** Tab-strip label for a browser tab: the host, or `New tab` when blank. */
export function browserTabTitle(url?: string | null): string {
  if (!url) return 'New tab'
  return hostOf(url) || 'New tab'
}
