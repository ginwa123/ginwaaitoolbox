/**
 * sseClient.ts
 *
 * Auto-reconnecting wrapper around the browser-native `EventSource`.
 *
 * Why this exists
 * ───────────────
 * The previous pattern in the desktop app (e.g. `App.vue` worker
 * stream, `ChatsList.vue` session stream, `ChatView.vue` chat + queue
 * streams) was a raw `new EventSource(url)` plus a hand-rolled
 * `onerror` callback. Three things went wrong:
 *
 *   1. **No reconnect on 3 of the 4 streams.** The browser's native
 *      `EventSource` does auto-retry on network-level failures with
 *      a 3 s default — but only if the server sends the SSE spec's
 *      `retry:` field, and ONLY for some failure modes (4xx/5xx are
 *      not retried by the spec). On a `nalar` server restart, the new
 *      process serves the new connection, but the old `EventSource`
 *      is permanently dead and never reconnects.
 *
 *   2. **Naive retry in `App.vue` had two bugs.** A 5 s
 *      `setTimeout(reconnect)` was not stored, so it could fire
 *      after the component unmounted (timer leak) and could fire
 *      after a *second* transient error had already reconnected
 *      successfully, killing the working connection. See §10 of
 *      `docs/sse-reconnect-plan.md`.
 *
 *   3. **No lifecycle awareness.** Laptops that suspend, tabs
 *      that get backgrounded, and Wi-Fi that drops then reappears
 *      are common — and the previous code did not pause retries
 *      while the tab was hidden, nor fast-path on the browser's
 *      `online` event.
 *
 * This module is the single source of truth for SSE reconnection in
 * the desktop app. It is consumed by `api/index.ts` (the 4 factory
 * functions there are thin adapters) and can be consumed directly
 * for new streams.
 *
 * Public surface
 * ──────────────
 *   - `createSseClient(opts) → SseClient`
 *       Owns one `EventSource`, one retry timer, and the
 *       `visibilitychange` / `online` listeners. All cleaned up in
 *       `.close()`.
 *   - `SseClient.close()` — terminal, no further reconnects.
 *   - `SseClient.reconnect()` — force a reconnect, resets attempt
 *       counter. Use it for a user-driven "Retry" button.
 *   - `SseClient.getState()` — synchronous read of the current
 *       state. Use it in templates / ref-bound UI.
 *   - `SseClient.onStateChange(cb)` — subscribe to state
 *       transitions. Returns an unsubscribe function. Use it to
 *       drive reactive UI (e.g. a "Reconnecting…" badge).
 *
 * State machine
 * ─────────────
 *
 *        construct
 *            │
 *            ▼
 *      ┌──────────┐
 *      │connecting│◄────────────────────────┐
 *      └────┬─────┘                         │
 *           │ 'connected' server event      │
 *           ▼                               │
 *       ┌──────┐ onerror                    │
 *       │ open │──────────────────┐         │
 *       └──┬───┘                  │         │
 *          │ .close()             │         │
 *          ▼                      ▼         │
 *      ┌────────┐  timer     ┌────────────┐ │
 *      │ closed │  fires     │reconnecting│─┘
 *      └────────┘            └─────┬──────┘
 *                                 │ too many errors
 *                                 │ OR non-recoverable 4xx/5xx
 *                                 │ on FIRST attempt
 *                                 ▼
 *                              ┌────────┐
 *                              │ failed │
 *                              └────────┘
 *
 * Notes:
 *   - `reconnecting → connecting` is the timer-or-event fast path
 *     (a fresh `EventSource` is constructed).
 *   - `failed` is terminal. The only way out is `.reconnect()` or
 *     constructing a new client.
 *   - `visibilitychange → visible` AND `online` event both
 *     fast-path `reconnecting → connecting` (cancel the timer,
 *     start a fresh attempt).
 */

/**
 * State emitted by `SseClient`. See the state machine in the file
 * header for transitions.
 *
 * - `connecting`:   An `EventSource` was just opened; waiting for the
 *                   first byte / the server's `connected` named event.
 * - `open`:         Server sent a `connected` named event. We are
 *                   live; data events are flowing.
 * - `reconnecting`: Stream was open, then `onerror` fired, and a
 *                   retry timer is pending (or we are paused waiting
 *                   for visibility / online).
 * - `closed`:       Consumer called `.close()`. Terminal.
 * - `failed`:       Terminal. Either the first attempt errored (4xx /
 *                   5xx) before any `open` fired, or
 *                   `maxAttempts` was reached.
 */
export type SseState =
  | 'connecting'
  | 'open'
  | 'reconnecting'
  | 'closed'
  | 'failed'

/**
 * Side-channel info attached to every state emission. Lets UI
 * (and tests) distinguish "first error before open" from "Nth error
 * after open" without re-implementing the logic.
 */
export interface SseStateInfo {
  /** 1 = first try, 2 = first retry, … */
  attempt: number
  /**
   * Set on `reconnecting`. The actual delay until the next attempt
   * (after jitter), in ms. Tests use this to assert the backoff
   * schedule deterministically.
   */
  nextDelayMs?: number
  /** Set on `reconnecting` / `failed`. The `error` event from the ES. */
  lastError?: Event
  /**
   * What triggered this transition. Useful for log/UX messages:
   *   - `error`            — the EventSource fired onerror
   *   - `closed`           — the EventSource fired a clean close (rare)
   *   - `online`           — the browser's `online` event fast-pathed us
   *   - `visible`          — the tab became visible while we were paused
   *   - `manual`           — the consumer called .close() or .reconnect()
   *   - `exhausted`        — `maxAttempts` reached (only on `failed`)
   *   - `non-recoverable`  — first-attempt failure (4xx/5xx) (only on `failed`)
   */
  reason?:
    | 'error'
    | 'closed'
    | 'online'
    | 'visible'
    | 'manual'
    | 'exhausted'
    | 'non-recoverable'
}

export interface SseClientOptions {
  /** URL to subscribe to. Required. */
  url: string
  /**
   * Event dispatcher. Called once per `data:` line the server sent.
   *
   * - `raw` is the unparsed payload string. The SseClient does
   *   NOT do JSON parsing — the adapter owns that. JSON
   *   buffering (multi-line payloads) is the adapter's
   *   responsibility, since the SseClient has no idea what
   *   payload format the server uses.
   * - `eventType` is the SSE `event:` name (`'message'` for the
   *   unnamed default, or the named event name like
   *   `'connected'` / `'queue_message'`).
   *
   * Throwing inside this callback is caught and logged — a
   * malformed event does NOT close the connection.
   */
  onEvent: (raw: string, eventType: string) => void
  /**
   * Fires once, after the server's first `connected` named event.
   * This is the canonical "we are live" signal. Do NOT treat the
   * raw `open` event (HTTP 200 + headers) as live — the
   * connection can still be rejected at the protocol level by
   * the server.
   *
   * The 'connected' event is ALSO passed to `onEvent` with
   * `eventType === 'connected'`, so adapters that want the
   * payload can read it from there.
   */
  onConnected?: () => void
  /**
   * Fires on every state transition. Use it to drive a Vue ref
   * for reactive UI (e.g. the `SseStatusBadge`).
   */
  onStateChange?: (state: SseState, info: SseStateInfo) => void
  /**
   * Initial backoff for the *first* retry. Doubles each subsequent
   * retry, capped at `maxDelayMs`. Default: 1 000 ms.
   */
  baseDelayMs?: number
  /**
   * Upper bound on the backoff delay (after jitter). Default:
   * 30 000 ms. The "Reconnecting…" badge can use this to give
   * the user a sense of how long the next attempt will take.
   */
  maxDelayMs?: number
  /**
   * Hard cap on reconnect attempts. After this many failed retries
   * (post-open), state becomes `failed` and no further retries
   * are scheduled. The first attempt does NOT count against this
   * cap (a 4xx on the first try already goes to `failed`
   * immediately). Default: `Infinity` (an SSE stream is expected
   * to live the lifetime of the page).
   */
  maxAttempts?: number
  /**
   * Random source for jitter. Override in tests to make the
   * backoff schedule deterministic. Default: `Math.random`.
   * Jitter formula: `delay = exp * (0.5 + 0.5 * random())`
   * (full-jitter pattern, AWS-style).
   */
  random?: () => number
  /**
   * Pause the retry timer while `document.hidden === true`.
   * The retry fires immediately on `visibilitychange → visible`.
   * Default: `true`. Set `false` for headless contexts or tests.
   */
  pauseWhenHidden?: boolean
  /**
   * Reconnect immediately on the browser's `online` event. Default:
   * `true`. The event target is `window` (override with
   * `onlineTarget` for tests).
   */
  reconnectOnOnline?: boolean
  /**
   * Override the `EventSource` constructor. Default:
   * `globalThis.EventSource`. Tests pass a mock factory here so
   * they can fire synthetic `open` / `error` / `message` events
   * without a real network.
   */
  EventSourceCtor?: typeof EventSource
  /**
   * Override the `visibilitychange` target. Default: `document`.
   * Tests may pass a mock to control visibility.
   */
  visibilityTarget?: Pick<Document, 'addEventListener' | 'removeEventListener' | 'hidden'>
  /**
   * Override the `online` event target. Default: `window`. Tests
   * may pass a mock to fire synthetic `online` events.
   */
  onlineTarget?: Pick<Window, 'addEventListener' | 'removeEventListener'>
  /**
   * Override `setTimeout` / `clearTimeout` for fake-timer tests.
   * Default: the global `setTimeout` / `clearTimeout`.
   */
  setTimeoutFn?: typeof setTimeout
  clearTimeoutFn?: typeof clearTimeout
  /**
   * The SSE event name that signals "the stream is live". The
   * default `'connected'` matches the backend's convention; expose
   * it for symmetry / future flexibility.
   */
  connectedEventName?: string
}

export interface SseClient {
  /**
   * Close the connection. Terminal — no further state changes, no
   * further retries, all listeners removed. Safe to call multiple
   * times.
   */
  close(): void
  /**
   * Force a reconnect attempt right now. Resets the attempt
   * counter to 0. If the connection is currently `open`, the
   * existing `EventSource` is closed and a new one is opened.
   * Intended for a user-driven "Retry" button on the `failed`
   * badge.
   */
  reconnect(): void
  /**
   * Synchronous read of the current state. Returns the most
   * recently emitted state.
   */
  getState(): SseState
  /**
   * Subscribe to state transitions. Returns an unsubscribe
   * function. Subscribers are NOT called for the state that was
   * current at the time of subscription — only for transitions
   * that happen AFTER subscribing. (If you need the current state
   * at subscription time, call `getState()` too.)
   */
  onStateChange(cb: (s: SseState, info: SseStateInfo) => void): () => void
}

/**
 * Create a self-managing SSE client with exponential backoff and
 * full jitter. See the file header for the state machine and the
 * public surface.
 *
 * @example
 *   const client = createSseClient({
 *     url: '/api/sessions/stream',
 *     onEvent: (raw, type) => console.log(type, raw),
 *     onConnected: () => console.log('live'),
 *     onStateChange: (s) => (sseState.value = s),
 *   })
 *   // later
 *   client.close()
 */
export function createSseClient(opts: SseClientOptions): SseClient {
  const baseDelayMs = opts.baseDelayMs ?? 1_000
  const maxDelayMs = opts.maxDelayMs ?? 30_000
  const maxAttempts = opts.maxAttempts ?? Infinity
  const random = opts.random ?? Math.random
  const pauseWhenHidden = opts.pauseWhenHidden ?? true
  const reconnectOnOnline = opts.reconnectOnOnline ?? true
  const setTimeoutFn = opts.setTimeoutFn ?? setTimeout
  const clearTimeoutFn = opts.clearTimeoutFn ?? clearTimeout
  const connectedEventName = opts.connectedEventName ?? 'connected'
  // Cast is safe: in browsers EventSource is a global, in jsdom the
  // setup.ts polyfill assigns it. Tests override via opts.
  const EventSourceCtor =
    opts.EventSourceCtor ??
    ((globalThis as { EventSource?: typeof EventSource }).EventSource as typeof EventSource)
  const visibilityTarget = (opts.visibilityTarget ??
    (typeof document !== 'undefined' ? document : null)) as Pick<
    Document,
    'addEventListener' | 'removeEventListener' | 'hidden'
  > | null
  const onlineTarget = (opts.onlineTarget ??
    (typeof window !== 'undefined' ? window : null)) as Pick<
    Window,
    'addEventListener' | 'removeEventListener'
  > | null

  // Mutable connection state
  let es: EventSource | null = null
  let retryTimer: ReturnType<typeof setTimeout> | null = null
  let attempt = 0
  let hasBeenOpen = false
  let state: SseState = 'connecting'
  const subscribers = new Set<(s: SseState, info: SseStateInfo) => void>()
  let closed = false

  function emitState(next: SseState, info: SseStateInfo): void {
    state = next
    for (const cb of subscribers) {
      try {
        cb(next, info)
      } catch (err) {
        // A buggy subscriber must not poison the others or the
        // connection. Log to console.error (not throw) so the
        // surface stays usable in dev. Production code is
        // expected to be careful; this is just defense-in-depth.
        console.error('[SseClient] onStateChange subscriber threw:', err)
      }
    }
  }

  function clearRetry(): void {
    if (retryTimer !== null) {
      clearTimeoutFn(retryTimer)
      retryTimer = null
    }
  }

  function start(): void {
    if (closed) return
    clearRetry()

    attempt += 1
    emitState('connecting', { attempt, reason: 'manual' })

    let instance: EventSource
    try {
      instance = new EventSourceCtor(opts.url)
    } catch (err) {
      // The constructor itself threw synchronously (e.g. invalid
      // URL). Treat as a first-attempt fatal error.
      handleError(
        err instanceof Event
          ? { reason: 'non-recoverable', lastError: err }
          : { reason: 'non-recoverable', lastError: new Event('error') },
      )
      return
    }
    es = instance

    instance.addEventListener(connectedEventName, (e: Event) => {
      // Server explicitly confirmed the stream is live. This is
      // the "open for business" signal — distinct from the raw
      // TCP/HTTP `open` event which only means the headers came
      // back OK.
      //
      // We mark the connection as "ever open" (so a 4xx/5xx on
      // the *next* attempt is still treated as recoverable and
      // goes through the backoff loop) but we DO NOT reset
      // `attempt` here. `attempt` tracks "how many start() calls
      // have we made" — the backoff formula `2 ** (attempt - 1)`
      // depends on it monotonically increasing across retries.
      // Resetting it in `connected` would cause the first retry
      // after a successful open to compute `2 ** -1 = 0.5` of
      // the base delay, halving the backoff and breaking the
      // exponential schedule. The right place to reset
      // `attempt` is `reconnect()` (a user-driven retry) and
      // construction (a fresh client).
      const me = e as MessageEvent
      const raw = typeof me.data === 'string' ? me.data : String(me.data ?? '')
      hasBeenOpen = true
      emitState('open', { attempt, reason: 'manual' })
      opts.onConnected?.()
      // Also pass through to onEvent so adapters that want the
      // payload (e.g. `createSseConnection` adds it to the
      // message stream with `type: 'connected'`) can read it.
      try {
        opts.onEvent(raw, connectedEventName)
      } catch (err) {
        console.error('[SseClient] onEvent subscriber threw on connected:', err)
      }
    })

    instance.addEventListener('message', (e: Event) => {
      const me = e as MessageEvent
      try {
        const raw = typeof me.data === 'string' ? me.data : String(me.data ?? '')
        opts.onEvent(raw, 'message')
      } catch (err) {
        console.error('[SseClient] onEvent subscriber threw on message:', err)
      }
    })

    instance.onerror = (e: Event) => {
      handleError({ reason: 'error', lastError: e })
    }
  }

  function handleError(info: { reason: SseStateInfo['reason']; lastError?: Event }): void {
    if (closed) return

    // Close the dead EventSource so it cannot fire onerror again.
    // Browsers fire onerror both on the initial error AND on every
    // internal retry attempt — we want exactly one error → one
    // attempt counter increment.
    if (es) {
      try {
        es.close()
      } catch {
        // Some polyfills throw on close; ignore.
      }
      es = null
    }

    // First-attempt failure (4xx/5xx, DNS error, etc.) is NOT
    // recoverable by retrying. The server actively rejected us
    // (or the URL is wrong). Going into a backoff loop here would
    // just hammer the server.
    if (!hasBeenOpen) {
      emitState('failed', {
        attempt,
        lastError: info.lastError,
        reason: info.reason === 'non-recoverable' ? 'non-recoverable' : 'error',
      })
      return
    }

    // We've been connected before, so a transient error is
    // worth retrying. Bump the attempt counter (already done in
    // start()) and decide whether to schedule or to give up.
    if (attempt > maxAttempts) {
      emitState('failed', {
        attempt,
        lastError: info.lastError,
        reason: 'exhausted',
      })
      return
    }

    scheduleRetry({ reason: 'error' })
  }

  function scheduleRetry(reasonInfo: { reason: 'error' | 'visible' | 'online' }): void {
    if (closed) return
    clearRetry()

    // While the tab is hidden, do not burn battery or hit the
    // server with retries. Wait for visibilitychange → visible
    // to fire `start()` instead. Tests that need to bypass this
    // can set `pauseWhenHidden: false` and pre-set
    // `visibilityTarget.hidden = false` (jsdom default).
    if (pauseWhenHidden && visibilityTarget && visibilityTarget.hidden) {
      emitState('reconnecting', {
        attempt,
        reason: 'error', // we are paused, but the cause was still the error
      })
      return
    }

    // Exponential backoff, full jitter (AWS pattern).
    //   exp = min(base * 2^(n-1), max)
    //   jitter = 0.5 + 0.5 * random()   // range [0.5, 1.0)
    //   delay = exp * jitter
    // With base=1s, max=30s, attempt=1, random=0.5:
    //   exp = 1000, jitter = 0.75, delay = 750 ms
    const exp = Math.min(baseDelayMs * 2 ** (attempt - 1), maxDelayMs)
    const jitter = 0.5 + 0.5 * random()
    const delay = exp * jitter

    emitState('reconnecting', {
      attempt,
      nextDelayMs: delay,
      reason: reasonInfo.reason,
    })
    retryTimer = setTimeoutFn(() => {
      retryTimer = null
      start()
    }, delay)
  }

  // ── DOM listeners ─────────────────────────────────────────────────────
  // Only attach when the target is available. In tests, callers
  // can pass mock targets or set `pauseWhenHidden: false`.

  function onVisibilityChange(): void {
    if (closed) return
    if (!visibilityTarget) return
    if (visibilityTarget.hidden) return
    // We just became visible. If we were waiting to retry, do it
    // now.
    if (state === 'reconnecting') {
      clearRetry()
      // Fast-path on visibility: open immediately, do not wait
      // for the timer. Mark the reason so logs / UI can show
      // "resumed on visibility" if they want to.
      emitState('reconnecting', { attempt, reason: 'visible' })
      start()
    }
  }

  function onOnline(): void {
    if (closed) return
    // Same fast-path: if we were in `reconnecting` because the
    // network died, retry immediately on `online`.
    if (state === 'reconnecting') {
      clearRetry()
      emitState('reconnecting', { attempt, reason: 'online' })
      start()
    }
  }

  if (visibilityTarget && typeof visibilityTarget.addEventListener === 'function') {
    visibilityTarget.addEventListener('visibilitychange', onVisibilityChange)
  }
  if (reconnectOnOnline && onlineTarget && typeof onlineTarget.addEventListener === 'function') {
    onlineTarget.addEventListener('online', onOnline)
  }

  // Wire the optional `opts.onStateChange` into the same
  // subscriber set the `.onStateChange(cb)` method uses. This
  // way the two entry points are equivalent and a throwing
  // opts.onStateChange is caught by the same try/catch in
  // `emitState` (it cannot break the connection).
  if (opts.onStateChange) {
    subscribers.add(opts.onStateChange)
  }

  // ── Kick off the first attempt ────────────────────────────────────────
  // We do this AFTER the listeners are attached so a synchronous
  // success / failure does not race the listener registration.
  start()

  return {
    close(): void {
      if (closed) return
      closed = true
      clearRetry()
      if (es) {
        try {
          es.close()
        } catch {
          // ignore
        }
        es = null
      }
      if (visibilityTarget && typeof visibilityTarget.removeEventListener === 'function') {
        visibilityTarget.removeEventListener('visibilitychange', onVisibilityChange)
      }
      if (reconnectOnOnline && onlineTarget && typeof onlineTarget.removeEventListener === 'function') {
        onlineTarget.removeEventListener('online', onOnline)
      }
      emitState('closed', { attempt, reason: 'manual' })
      subscribers.clear()
    },

    reconnect(): void {
      if (closed) return
      if (es) {
        try {
          es.close()
        } catch {
          // ignore
        }
        es = null
      }
      clearRetry()
      attempt = 0
      hasBeenOpen = false
      start()
    },

    getState(): SseState {
      return state
    },

    onStateChange(cb: (s: SseState, info: SseStateInfo) => void): () => void {
      subscribers.add(cb)
      return () => {
        subscribers.delete(cb)
      }
    },
  }
}
