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
