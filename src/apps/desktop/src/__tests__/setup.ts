/**
 * Vitest test setup.
 *
 * Runs before every test file. Polyfills browser APIs that jsdom does
 * not implement so module-level code in `src/api/index.ts` (which calls
 * `new EventSource(...)` at function entry) can be imported without
 * crashing during unit tests.
 *
 * The stub is intentionally inert: it accepts a URL, exposes the same
 * `addEventListener` / `onmessage` / `close` surface, but never fires
 * events. Tests that need real SSE behavior should mock the api module
 * instead of relying on this stub.
 */

class EventSourceStub {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSED = 2
  readonly readyState: number = EventSourceStub.CLOSED
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  url: string = ''
  withCredentials: boolean = false

  constructor(url?: string) {
    this.url = url ?? ''
  }

  addEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  removeEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  dispatchEvent(_event: Event): boolean {
    return true
  }
  close(): void {}
}

if (typeof (globalThis as { EventSource?: unknown }).EventSource === 'undefined') {
  ;(globalThis as { EventSource: unknown }).EventSource = EventSourceStub
}

// jsdom does not ship ResizeObserver, but VirtualScroller.vue instantiates
// one in onMounted. The stub matches the EventSource polyfill above: inert,
// accepts the calls, never fires — tests that need real resize behavior
// should mock the component instead of relying on this stub.
if (typeof (globalThis as { ResizeObserver?: unknown }).ResizeObserver === 'undefined') {
  ;(globalThis as { ResizeObserver: unknown }).ResizeObserver = class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  }
}

// Stub global fetch so relative-URL API calls in tests don't throw
// "Failed to parse URL from /api/..." TypeErrors. Tests that need
// real API behavior should mock the api module (vi.spyOn(api, ...))
// instead of letting this stub fire. Without this stub, store actions
// like `fetchKanbanColumns` and `loadFoldersForCwdPicker` produce
// unhandled rejections during test cleanup and vitest counts them
// as errors (exit 1) even when the test itself passes.
//
// The stub resolves with a generic 404 JSON response — every apiFetch
// call goes through `silent` checks before notifyError, so callers can
// observe the rejection normally; the stub just avoids the URL-parse
// TypeError that would otherwise escape the test.
// Replace global fetch with a stub that returns 404 for any URL.
// jsdom env may already provide its own fetch, so we always overwrite.
// Without this stub, unmocked api calls in tests hit `new URL(/api/...)`
// which fails to parse (no base URL set up) and produces unhandled
// rejections that vitest counts as errors (exit 1).
const stubFetch: typeof fetch = async () =>
  new Response(JSON.stringify({ error: 'fetch stubbed in test env' }), {
    status: 404,
    headers: { 'Content-Type': 'application/json' },
  })
;(globalThis as { fetch: typeof fetch }).fetch = stubFetch
