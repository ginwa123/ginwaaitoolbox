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
 *       `.close()`. **The constructor is fully async** — the
 *       initial `start()` is deferred to the next macrotask
 *       (`setTimeout(start, 0)`) so the HTTP request does not
 *       fire synchronously inside the caller. Tests that interact
 *       with `instances[0]` immediately after construction must
 *       call `vi.advanceTimersByTime(0)` to flush the deferred
 *       start.
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
 *   - `pagehide` AND `beforeunload` (added in the 2026-01-15 fix)
 *     call `close()` synchronously. Without this, the browser only
 *     eventually tears down the underlying socket on page unload,
 *     and the SSE connection lingers in the network panel as
 *     "open" / "pending" until the server-side timeout fires. The
 *     browser's `EventSource` close method is also needed to make
 *     the browser drop the stream from the network panel
 *     immediately on refresh / tab close / navigation. Set
 *     `closeOnUnload: false` to opt out (tests, SSR).
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
export type SseState = 'connecting' | 'open' | 'reconnecting' | 'closed' | 'failed'

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
  reason?: 'error' | 'closed' | 'online' | 'visible' | 'manual' | 'exhausted' | 'non-recoverable'
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
   *   `'connected'` / `'queue_message'`). For custom named
   *   events to be routed here, list them in
   *   `additionalEventTypes` — the SseClient does NOT
   *   auto-discover server-sent event names, it must be told
   *   which ones to listen for. The `'connected'` event is
   *   always registered automatically.
   *
   * Throwing inside this callback is caught and logged — a
   * malformed event does NOT close the connection.
   */
  onEvent: (raw: string, eventType: string) => void
  /**
   * Additional named SSE event types to route to `onEvent`.
   * The reserved names `'connected'` (handled internally:
   * fires `onConnected` and transitions to `'open'`) and
   * `'message'` (the unnamed default) are always registered;
   * duplicates in this list are silently de-duplicated.
   *
   * Why this option exists
   * ──────────────────────
   * The browser's `EventSource` fires each server-side
   * `event: <name>` to listeners registered for THAT specific
   * name. The SseClient can only register listeners it knows
   * about up front, so consumers must declare which custom
   * event types they care about. Without this, named events
   * like `queue_message` are silently dropped on the floor
   * — they reach the network but never reach the JS handler.
   *
   * Example — the queue-messages stream:
   *   createSseClient({
   *     url: '/api/.../queue_messages/stream',
   *     additionalEventTypes: ['queue_message'],
   *     onEvent: (raw, type) => {
   *       if (type === 'queue_message') { ... }
   *     },
   *   })
   *
   * Unknown / never-fired names are harmless (the listener
   * simply never fires).
   */
  additionalEventTypes?: string[]
  /**
   * Heartbeat data to drop silently from the default
   * `'message'` event stream. The backend SSE manager sends
   * `data: ping\n\n` every ~15 s to keep the connection alive
   * through proxies / NATs; surfacing that to consumers
   * leaks the protocol detail and (in consumers that
   * JSON-buffer the data, like the queue-messages stream)
   * grows an ever-larger buffer that never flushes, because
   * `'ping'` contains no `{` or `}` to anchor a JSON slice.
   *
   * Default: `'ping'` (matches `sse_manager.sendHeartbeat`).
   * Set to `null` to disable the filter (every default
   * `'message'` event reaches `onEvent`, including
   * heartbeats).
   *
   * Only applies to the default `'message'` event. Heartbeats
   * sent as custom named events (e.g. `event: heartbeat`) are
   * not affected — declare and ignore them in the consumer
   * instead.
   */
  heartbeatData?: string | null
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
   * Close the connection automatically on `pagehide` (modern,
   * covers bfcache) and `beforeunload` (legacy fallback). When
   * the user refreshes the page, closes the tab, or navigates
   * away, the browser will eventually tear down the underlying
   * socket — but the SSE connection lingers in the network
   * panel as "open" / "pending" and the server does not know
   * the client is gone until the server-side timeout fires.
   * Listening for `pagehide` + `beforeunload` and calling
   * `close()` synchronously makes the browser drop the stream
   * from the network panel immediately.
   *
   * Default: `true`. Set `false` in tests (to avoid extra
   * listeners) or in headless contexts that have no `window`.
   */
  closeOnUnload?: boolean
  /**
   * Override the `pagehide` / `beforeunload` event target.
   * Default: `window`. Tests may pass a mock to fire synthetic
   * unload events.
   */
  unloadTarget?: Pick<Window, 'addEventListener' | 'removeEventListener'>
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
  // Heartbeat data to silently drop from the default 'message' event.
  // Default: 'ping' (matches sse_manager.sendHeartbeat's literal
  // `data: ping\n\n`). `null` disables the filter entirely — see the
  // `heartbeatData` option doc for why this exists.
  const heartbeatData: string | null =
    opts.heartbeatData === undefined ? 'ping' : opts.heartbeatData
  // Deduplicated list of custom named event types the consumer wants
  // routed to `onEvent`. Reserved names (`'connected'`, `'message'`)
  // are always handled by the SseClient's own listeners, so including
  // them here is a no-op. We filter them out below to avoid
  // double-registration (which would fire `onEvent` twice per event).
  const reservedEventNames = new Set<string>(['connected', 'message'])
  const additionalEventTypes: string[] = (opts.additionalEventTypes ?? []).filter(
    (name) => !reservedEventNames.has(name),
  )
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
  const closeOnUnload = opts.closeOnUnload ?? true
  const unloadTarget = (opts.unloadTarget ??
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
        // Drop heartbeats before they reach the consumer. The
        // backend sends `data: ping\n\n` as a keepalive; in
        // consumers that JSON-buffer incoming data (e.g. the
        // queue-messages stream), every heartbeat appends to
        // the buffer and the buffer never drains (no `{`/`}`).
        // This is a generic SseClient concern — the heartbeat
        // exists to keep the connection alive, which is the
        // SseClient's job, not the consumer's.
        if (heartbeatData !== null && raw === heartbeatData) {
          return
        }
        opts.onEvent(raw, 'message')
      } catch (err) {
        console.error('[SseClient] onEvent subscriber threw on message:', err)
      }
    })

    // Register listeners for any additional named event types the
    // consumer declared (e.g. 'queue_message'). Each one is
    // dispatched to `onEvent` with the event name as the type
    // argument, matching the contract documented on `onEvent` and
    // on `createSseConnection`. We register inside `start()` (not
    // once, at construction) so the listeners are re-attached on
    // reconnect — the EventSource is rebuilt on every retry, so any
    // listeners on the previous instance are gone.
    for (const eventName of additionalEventTypes) {
      instance.addEventListener(eventName, (e: Event) => {
        const me = e as MessageEvent
        try {
          const raw = typeof me.data === 'string' ? me.data : String(me.data ?? '')
          opts.onEvent(raw, eventName)
        } catch (err) {
          console.error(`[SseClient] onEvent subscriber threw on ${eventName}:`, err)
        }
      })
    }

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
      // Deferred to the next macrotask so the tab-becoming-visible
      // path doesn't fire `new EventSource(url)` synchronously —
      // see the constructor's deferral comment for the full
      // rationale (HTTP/1.1 6-connection pool saturation).
      setTimeout(start, 0)
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

  function onPageHide(): void {
    // `pagehide` / `beforeunload` are the "user is leaving the
    // page" signal (refresh, tab close, navigation). The unload
    // handler MUST be synchronous — the browser will not await
    // a Promise. Just call `teardown()` and let the browser
    // close the socket. Without this, the SSE connection
    // lingers in the network panel as "open" / "pending" and
    // the server does not know the client is gone until the
    // server-side timeout fires.
    teardown()
  }

  if (visibilityTarget && typeof visibilityTarget.addEventListener === 'function') {
    visibilityTarget.addEventListener('visibilitychange', onVisibilityChange)
  }
  if (reconnectOnOnline && onlineTarget && typeof onlineTarget.addEventListener === 'function') {
    onlineTarget.addEventListener('online', onOnline)
  }
  if (closeOnUnload && unloadTarget && typeof unloadTarget.addEventListener === 'function') {
    unloadTarget.addEventListener('pagehide', onPageHide)
    unloadTarget.addEventListener('beforeunload', onPageHide)
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
  //
  // Defer the start() call to the next macrotask (setTimeout 0) so
  // the SseClient constructor returns immediately without initiating
  // the HTTP request synchronously. This makes the SSE setup "fully
  // async" — callers (e.g. `kanbanSseStore.initKanbanSse`) can be
  // `await`ed, and other in-flight fetch API calls (workspace data,
  // chat history, etc.) can proceed before the EventSource connection
  // is established. Without this defer, the SSE HTTP request would
  // race with the same-tick fetches and saturate the browser's
  // per-origin connection pool (6 in HTTP/1.1).
  //
  // The `onError` synchronous-constructor-throw path still works:
  // the throw happens inside `start()` after the deferral, so the
  // first-attempt fatal error is reported on the next tick (slightly
  // later than before, but still before any reconnect could fire).
  setTimeout(start, 0)

  // Shared cleanup path. Called by both the public `.close()`
  // method and the `pagehide` / `beforeunload` listener. Idempotent
  // (the `closed` guard at the top makes repeat calls a no-op),
  // so it is safe to call from a stale unload handler after
  // `.close()` has already been invoked.
  function teardown(): void {
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
    if (
      reconnectOnOnline &&
      onlineTarget &&
      typeof onlineTarget.removeEventListener === 'function'
    ) {
      onlineTarget.removeEventListener('online', onOnline)
    }
    if (closeOnUnload && unloadTarget && typeof unloadTarget.removeEventListener === 'function') {
      unloadTarget.removeEventListener('pagehide', onPageHide)
      unloadTarget.removeEventListener('beforeunload', onPageHide)
    }
    emitState('closed', { attempt, reason: 'manual' })
    subscribers.clear()
  }

  return {
    close(): void {
      teardown()
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
