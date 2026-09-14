import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

/**
 * The browser window's chrome bar, tested BEHAVIOURALLY.
 *
 * `src/apps/desktop_app/browser_chrome.js` is embedded byte-for-byte into
 * `nalar-desktop` (`@embedFile`, see webview_lib.zig) and handed to
 * `webview_init`, so it runs inside any page the window loads. These tests
 * execute those exact bytes — a source grep would happily pass on a file the
 * webview could never run.
 *
 * The script is evaluated against an iframe's document and injected
 * `location`/`history` stand-ins (the same names it closes over in the real
 * page), which gives each test an isolated page AND makes navigation
 * observable: jsdom refuses real navigation, so a "did it navigate?" assertion
 * needs the seam. No prototype patching, no shared global state between tests.
 */

/**
 * Locate a file in the desktop-app shell module.
 *
 * Vitest rewrites `import.meta.url` into a non-file URL, so the path is
 * resolved from the process cwd instead — which is `src/apps/desktop` when the
 * suite is run through `pnpm`, and the repo root when it is run from there.
 */
function shellFile(name: string): string {
  const candidates = [
    resolve(process.cwd(), 'src/apps/desktop_app', name), // cwd = repo root
    resolve(process.cwd(), '../desktop_app', name), // cwd = src/apps/desktop
  ]
  const found = candidates.find((candidate) => existsSync(candidate))
  if (!found) throw new Error(`cannot locate ${name} (tried ${candidates.join(', ')})`)
  return found
}

const CHROME_SOURCE = readFileSync(shellFile('browser_chrome.js'), 'utf8')

const BAR_ID = '__nalar_browser_chrome__'
const ERROR_ID = '__nalar_browser_chrome_error__'
const GOOGLE = 'https://www.google.com/search?q='

/** The exact bytes the shell embeds, wrapped so the page's globals are injectable. */
const runChrome = new Function(
  'document',
  'location',
  'history',
  'MutationObserver',
  'queueMicrotask',
  CHROME_SOURCE,
) as (
  document: Document,
  location: { href: string; reload: () => void },
  history: { back: () => void; forward: () => void },
  observer: typeof MutationObserver,
  queue: (fn: () => void) => void,
) => void

interface ChromeEnv {
  doc: Document
  nav: { href: string; reload: ReturnType<typeof vi.fn> }
  history: { back: ReturnType<typeof vi.fn>; forward: ReturnType<typeof vi.fn> }
  bar: () => HTMLElement | null
  input: () => HTMLInputElement
  error: () => HTMLElement | null
  removeBar: () => void
}

function bootChrome(initialHref = 'https://start.example/page'): ChromeEnv {
  const iframe = document.createElement('iframe')
  document.body.appendChild(iframe)
  const doc = iframe.contentDocument
  if (!doc) throw new Error('jsdom did not provide an iframe document')
  doc.documentElement.innerHTML = '<head></head><body><div id="page">third-party</div></body>'

  const nav = { href: initialHref, reload: vi.fn() }
  const history = { back: vi.fn(), forward: vi.fn() }
  runChrome(doc, nav, history, MutationObserver, queueMicrotask)
  // Whichever branch the asset took (`readyState` is jsdom's business), the bar
  // must be up. The listener stays attached, so a second dispatch is meaningful.
  doc.dispatchEvent(new Event('DOMContentLoaded'))

  return {
    doc,
    nav,
    history,
    bar: () => doc.getElementById(BAR_ID),
    input: () => doc.querySelector('[data-nalar-browser-chrome-address]') as HTMLInputElement,
    error: () => doc.getElementById(ERROR_ID),
    removeBar: () => doc.getElementById(BAR_ID)?.remove(),
  }
}

/** Let the asset's coalescing microtask (and any observer callback) run. */
async function settle(): Promise<void> {
  await Promise.resolve()
  await new Promise((resolve) => setTimeout(resolve, 0))
}

function pressEnter(input: HTMLInputElement, value?: string): void {
  if (value !== undefined) input.value = value
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
}

afterEach(() => {
  document.body.innerHTML = ''
})

describe('browser_chrome.js (the injected bar)', () => {
  it('is the asset the shell embeds, with no inline script and no eval', () => {
    const zig = readFileSync(shellFile('webview_lib.zig'), 'utf8')
    expect(zig).toContain('@embedFile("browser_chrome.js")')
    expect(zig).toContain('webview_init(w, browser_chrome_js)')
    // A page's `script-src` cannot block it and there is nothing to inject.
    expect(CHROME_SOURCE).not.toMatch(/<script/i)
    expect(CHROME_SOURCE).not.toMatch(/\beval\s*\(/)
  })

  it('mounts the bar on DOMContentLoaded, appended last with the max z-index', async () => {
    const env = bootChrome()
    expect(env.bar()).not.toBeNull()
    // Appended LAST, so it wins equal-z-index ties against the page's nodes.
    expect(env.doc.documentElement.lastElementChild?.id).toBe(BAR_ID)
    expect(env.bar()!.style.zIndex).toBe('2147483647')
    expect(env.bar()!.style.position).toBe('fixed')

    // The DOMContentLoaded wiring: drop the bar, dispatch the event, it returns.
    env.removeBar()
    expect(env.bar()).toBeNull()
    env.doc.dispatchEvent(new Event('DOMContentLoaded'))
    await settle()
    expect(env.bar()).not.toBeNull()
  })

  it('fills the address input from location.href', () => {
    const env = bootChrome('https://github.com/nalar/nalar')
    expect(env.input().value).toBe('https://github.com/nalar/nalar')
  })

  it('restores the bar when the page strips it', async () => {
    const env = bootChrome()
    env.removeBar()
    await settle()
    expect(env.bar()).not.toBeNull()
  })

  it('gives up after the removal budget: the 5th removal is final, with no further remounts', async () => {
    const env = bootChrome()
    // The budget is bounded work: removals 1..4 are each recovered.
    for (let removal = 1; removal <= 4; removal += 1) {
      env.removeBar()
      await settle()
      // (eslint-plugin-jest forbids a message argument, hence the bare expect.)
      expect(env.bar()).not.toBeNull()
    }
    // The 5th exhausts the budget: the observer disconnects and the bar stays
    // gone (zero idle CPU — no timers were ever started).
    env.removeBar()
    await settle()
    expect(env.bar()).toBeNull()

    // Nothing brings it back, not even a page mutation afterwards.
    env.doc.documentElement.appendChild(env.doc.createElement('div'))
    await settle()
    expect(env.bar()).toBeNull()
  })

  it('normalizes a bare host on Enter and navigates the window', () => {
    const env = bootChrome()
    pressEnter(env.input(), 'example.com')
    expect(env.nav.href).toBe('https://example.com')
    // The bar shows where it is going even in a context that refuses the load.
    expect(env.input().value).toBe('https://example.com')
  })

  it('turns a plain phrase into a Google search', () => {
    const env = bootChrome()
    pressEnter(env.input(), 'zig lang')
    expect(env.nav.href).toBe(`${GOOGLE}${encodeURIComponent('zig lang')}`)
  })

  it('keeps a host:port address usable instead of reading it as a scheme', () => {
    const env = bootChrome()
    pressEnter(env.input(), 'localhost:5173')
    expect(env.nav.href).toBe('https://localhost:5173')
  })

  it('refuses javascript: on Enter: no navigation, an inline reason', () => {
    const env = bootChrome()
    const before = env.nav.href
    pressEnter(env.input(), 'javascript:alert(1)')
    expect(env.nav.href).toBe(before)
    expect(env.input().value).toBe('javascript:alert(1)')
    expect(env.error()).not.toBeNull()
    expect(env.error()!.textContent).toContain('javascript')
    expect(env.error()!.style.display).toBe('block')
  })

  it('refuses file: and data: too, and clears the reason on the next edit', () => {
    const env = bootChrome()
    const before = env.nav.href
    pressEnter(env.input(), 'file:///etc/passwd')
    expect(env.nav.href).toBe(before)
    pressEnter(env.input(), 'data:text/html,<h1>x</h1>')
    expect(env.nav.href).toBe(before)
    // The error clears as soon as the user edits the address.
    env.input().dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }))
    expect(env.error()!.style.display).toBe('none')
  })

  it('wires ←/→/↻ to the engine history and reload paths', () => {
    const env = bootChrome()
    const buttons = Array.from(env.bar()!.querySelectorAll('button'))
    expect(buttons).toHaveLength(3)
    buttons[0]!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    buttons[1]!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    buttons[2]!.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(env.history.back).toHaveBeenCalledTimes(1)
    expect(env.history.forward).toHaveBeenCalledTimes(1)
    expect(env.nav.reload).toHaveBeenCalledTimes(1)
  })

  it('Escape restores the address from location.href and hides the reason', () => {
    const env = bootChrome('https://start.example/page')
    pressEnter(env.input(), 'javascript:alert(1)')
    env.input().dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(env.input().value).toBe('https://start.example/page')
    expect(env.error()!.style.display).toBe('none')
  })
})
