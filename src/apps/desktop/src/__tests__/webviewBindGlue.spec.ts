import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The `webview_bind` JS contract, tested against the REAL vendored glue.
 *
 * Why this file exists: the shell originally bound `"nalarBrowser.open"`, and
 * the vendored glue does `window[name] = …` with the name VERBATIM — no
 * namespace walking — so it created `window["nalarBrowser.open"]` and left
 * `window.nalarBrowser` undefined. The shell looked wired; the SPA could never
 * see it; the button silently did nothing. A source grep would not have caught
 * that, so this spec extracts the glue out of `vendor/webview/webview.h` and
 * EXECUTES it, then checks both halves of the contract the Zig side depends on:
 *
 *  1. the name shape (flat, because of the glue), and
 *  2. the request JSON the callback receives (`{id, method, params}` with
 *     `params` = the JS arguments array — what `browser_bridge.zig` parses).
 */

const GLUE_START = 'function generateId() {'
const GLUE_END = 'window.__webview__ = new Webview();'

/**
 * Resolve a repo-relative path. Vitest rewrites `import.meta.url` into a
 * non-file URL, so this goes through the process cwd: `src/apps/desktop` when
 * run through pnpm, the repo root when run from there.
 */
function repoFile(rel: string): string {
  const candidates = [resolve(process.cwd(), rel), resolve(process.cwd(), '../../..', rel)]
  for (const candidate of candidates) {
    try {
      readFileSync(candidate)
      return candidate
    } catch {
      /* try the next root */
    }
  }
  throw new Error(`cannot locate ${rel} (tried ${candidates.join(', ')})`)
}

/** Extract the glue from the C++ string literal and unescape its line breaks. */
function extractGlue(): string {
  const header = readFileSync(repoFile('vendor/webview/webview.h'), 'utf8')
  const start = header.indexOf(GLUE_START)
  const end = header.indexOf(GLUE_END, start)
  if (start === -1 || end === -1) {
    throw new Error('the vendored webview glue moved — update this test')
  }
  return (
    header
      .slice(start, end + GLUE_END.length)
      // Upstream builds this literal by splicing the platform's `post_fn`
      // expression in; our harness passes that identifier as a parameter.
      .replace(/"\s*\+\s*\n\s*post_fn\s*\+\s*"/g, 'post_fn')
      // Every glue line ends with `\n\` (a C++ string-literal continuation).
      .replace(/\\n\\\n/g, '\n')
      .replace(/\\"/g, '"')
      .replace(/\\'/g, "'")
  )
}

/** Fail loudly if upstream adds another C++ splice this test does not handle. */
function assertNoSpliceLeft(glue: string): void {
  if (glue.includes('post_fn + "') || glue.includes('" +\n')) {
    throw new Error('an unhandled C++ splice is still in the extracted glue — update this test')
  }
}

interface GlueHarness {
  window: Record<string, unknown>
  posts: string[]
  onBind: (name: string) => void
}

function bootGlue(): GlueHarness {
  const posts: string[] = []
  const win: Record<string, unknown> = {}
  const glue = extractGlue()
  assertNoSpliceLeft(glue)
  // `post_fn` is upstream's platform splice point; here it records the message.
  // The glue mints request ids via `var crypto = window.crypto || …`, so the
  // fake window needs one — jsdom's `window.crypto` has no getRandomValues.
  const cryptoStub = {
    getRandomValues: (bytes: Uint8Array): Uint8Array => {
      for (let i = 0; i < bytes.length; i += 1) bytes[i] = i
      return bytes
    },
  }
  win.crypto = cryptoStub
  const factory = new Function('window', 'post_fn', `${glue}\nreturn window.__webview__;`) as (
    window: Record<string, unknown>,
    post: (message: string) => void,
  ) => { onBind: (name: string) => void }
  const webview = factory(win, (message: string) => {
    posts.push(message)
  })
  return { window: win, posts, onBind: (name) => webview.onBind(name) }
}

/** The binding names the shell installs, read from the Zig source. */
function shellBindingNames(): string[] {
  const source = readFileSync(repoFile('src/apps/desktop_app/browser_bridge.zig'), 'utf8')
  return [...source.matchAll(/webview_bind\(w, "([^"]+)"/g)].map((match) => match[1] as string)
}

describe('webview_bind glue contract', () => {
  it('binds a flat name as a real window property', () => {
    const glue = bootGlue()
    glue.onBind('nalarBrowserOpen')
    expect(typeof glue.window.nalarBrowserOpen).toBe('function')
  })

  it('a dotted name is a FLAT property — window.nalarBrowser stays undefined', () => {
    // This is precisely the bug the shell shipped once.
    const glue = bootGlue()
    glue.onBind('nalarBrowser.open')
    expect(glue.window.nalarBrowser).toBeUndefined()
    expect(typeof glue.window['nalarBrowser.open']).toBe('function')
  })

  it('posts { id, method, params } — the exact request the Zig callback parses', () => {
    const glue = bootGlue()
    glue.onBind('nalarBrowserOpen')
    const open = glue.window.nalarBrowserOpen as (...args: unknown[]) => Promise<unknown>
    void open('tab_1', 'https://example.com')

    expect(glue.posts).toHaveLength(1)
    const request = JSON.parse(glue.posts[0] as string) as {
      id?: unknown
      method?: unknown
      params?: unknown
    }
    expect(typeof request.id).toBe('string')
    expect(request.method).toBe('nalarBrowserOpen')
    // `browser_bridge.zig#parseParams` reads exactly this array.
    expect(request.params).toEqual(['tab_1', 'https://example.com'])
  })

  it('the shell binds exactly three flat names', () => {
    const names = shellBindingNames()
    expect(names).toEqual(['nalarBrowserOpen', 'nalarBrowserStatus', 'nalarBrowserClose'])
    for (const name of names) {
      // One JS identifier: the glue creates `window[name]`, so a dot would make
      // the binding unreachable as a property of `window`.
      expect(name).toMatch(/^[A-Za-z_$][A-Za-z0-9_$]*$/)
    }
  })
})
