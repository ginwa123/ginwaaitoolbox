# Plan: Frontend SSE Auto-Reconnect

> **Goal:** When a Server-Sent Events (SSE) stream disconnects on the
> frontend (network blip, server restart, sleep/wake, dev-tools offline),
> the client should reconnect automatically with sensible backoff and
> keep the UI in sync — instead of silently dying until the user reloads.

---

## 1. Current state (what's broken)

A `rg` of the desktop frontend surfaces **4 `EventSource` connections** in
3 components (plus a stub):

| # | File | URL | Reconnect? |
|---|------|-----|-----------|
| 1 | `App.vue` — `initWorkersSse()` | `GET /api/workers/stream` | **Yes, but naive** (hard-coded `setTimeout(…, 5000)`) and contains a **bug** (see §1.1) |
| 2 | `ChatsList.vue` — `connectSessionsSse()` | `GET /api/sessions/stream` | **No** — onError only logs |
| 3 | `ChatView.vue` — `connectSse()` (chat stream) | `GET /api/llm/stream/{sessionId}` | **No** — onError only resets `isStreaming` |
| 4 | `ChatView.vue` — `connectSse()` (queue stream) | `GET /api/llm/session/{id}/queue_messages/stream` | **No** — onError only logs |
| 5 | `Sidebar.vue` — `connectSessionsSse()` | (currently a no-op stub that just logs) | N/A — the real connection lives in `ChatsList.vue` |

None of them have:
- Exponential backoff
- Jitter (thundering-herd risk on server restart)
- Tab-visibility awareness (huge battery waste, also a common failure mode on laptops that suspend)
- `online` / `offline` awareness
- A max-retry cap (a 404 will loop forever)
- UI feedback so the user knows the stream is recovering
- An `onStateChange` channel for the rest of the app to react to (e.g. show a "reconnecting…" badge)

### 1.1 Latent bug in `App.vue` (worth fixing in the same change)

```ts
// App.vue:38–57
const initWorkersSse = () => {
  if (workersEventSource) workersEventSource.close()
  workersEventSource = api.createWorkersSseConnection(
    handleWorkerEvent,
    (error) => {
      console.error('[App] Workers SSE error:', error)
      setTimeout(initWorkersSse, 5000)   // ← (A) timer not stored, can't be cancelled
    },
    () => { /* onConnected */ },
  )
}
```

Two real issues here, both of which the new client must avoid:

1. **Timer leak on unmount.** If the component unmounts (or the user
   switches away) while a 5 s timer is pending, the timer fires,
   creates a *new* `EventSource`, and holds a reference that prevents
   GC. `onUnmounted` closes the *current* ES, but not the next one
   the timer will create.
2. **Race that closes a working connection.** If the server
   reconnects successfully (onerror → onopen) and *then* a *second*
   transient error fires before the timer for the first error is
   cancelled, that pending timer will call `initWorkersSse()` →
   `close()` on the **currently working** `EventSource`, killing it.

The new `SseClient` will close over its own retry timer and cancel it
on `onopen` and on manual `close()`.

---

## 2. Goals & non-goals

### Goals

- **G1.** All 4 SSE streams auto-reconnect after a disconnect.
- **G2.** Exponential backoff with full jitter (AWS pattern):
  `delay = min(base * 2^(n-1), max) * (0.5 + rand()*0.5)`.
  Defaults: `base = 1 s`, `max = 30 s`, `maxAttempts = ∞` (SSE is
  expected to live the lifetime of the page).
- **G3.** Pause retry timer when `document.visibilityState === 'hidden'`
  (laptops sleeping, dev-tools backgrounded). Reconnect immediately
  on `visibilitychange → visible` if the stream is currently down.
- **G4.** Reconnect immediately on the browser's `online` event (covers
  Wi-Fi reconnect, dev-tools "offline" → "online", VPN reconnect).
- **G5.** Give up cleanly (and emit `failed`) when the server rejects
  the connection with a non-recoverable error (e.g. 404 / 500 on the
  *first* attempt). Distinguish "never connected" from "connected
  then dropped" via a `hasBeenOpen` flag.
- **G6.** Single source of truth — the new client lives in
  `helpers/sseClient.ts` and is used by all 4 streams.
- **G7.** UI shows a "Reconnecting…" indicator on the chat header /
  sidebar when state ≠ `open` (so the user knows messages are
  missing). Use a small inline pill, not a modal.
- **G8.** Unit-tested with vitest fake timers. The current
  `__tests__/setup.ts` `EventSourceStub` is the right place to extend.

### Non-goals

- **NG1.** No change to the server-side SSE handlers. The client
  works with the current `/api/.../stream` endpoints.
- **NG2.** No protocol change to the SSE payload (no new `event:`
  types required). The existing `connected` named event stays the
  "I'm live" signal.
- **NG3.** No de-duplication of replayed events. If the server
  replays from a checkpoint on reconnect, that's the server's job.
  We will *not* try to detect duplicates in the client.

---

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  Component (App.vue / ChatView.vue / ChatsList.vue)                  │
│                                                                      │
│   const client = api.createSseConnection(sessionId, onMsg, onConn)  │
│   client.onStateChange = (s) => { sseState.value = s }              │
│                                                                      │
│   onUnmounted(() => client.close())                                  │
└──────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│  api/index.ts                                                        │
│   createSseConnection / createSessionsSseConnection /                │
│   createQueueMessagesSseConnection / createWorkersSseConnection      │
│                                                                      │
│   Each one is a thin adapter:                                        │
│     - hard-codes the URL                                             │
│     - wraps the existing JSON buffering logic into onEvent()         │
│     - delegates the connection lifecycle to SseClient                │
└──────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│  helpers/sseClient.ts (NEW)                                          │
│                                                                      │
│   - Manages one EventSource instance                                 │
│   - Exponential backoff with jitter                                  │
│   - visibilitychange + online listeners                              │
│   - Public state: connecting | open | reconnecting | closed | failed │
│   - .close() / .reconnect() / .onStateChange()                       │
└──────────────────────────────────────────────────────────────────────┘
```

Call-site diff is minimal because `SseClient.close()` matches the
`EventSource.close()` signature, and the 3 call sites that hold a
reference only ever call `.close()` on it.

---

## 4. New file: `src/apps/desktop/src/helpers/sseClient.ts`

```ts
// helpers/sseClient.ts
//
// Auto-reconnecting wrapper around the browser-native EventSource.
// One instance = one stream. Lifecycle methods (.close / .reconnect)
// are owned by the consumer; timers and DOM listeners are owned by
// this module and cleaned up in .close().

import { onScopeDispose } from 'vue'   // (optional) auto-cleanup in
                                       // component setup scope

export type SseState =
  | 'connecting'   // EventSource just (re)opened, waiting for first byte
  | 'open'         // we received a server 'connected' named event
  | 'reconnecting' // we lost the stream, will retry on a timer
  | 'closed'       // consumer called .close() — terminal
  | 'failed'       // exhausted retries OR non-recoverable (4xx/5xx on 1st attempt)

export interface SseClientOptions<T> {
  url: string
  /** Parsed-event dispatcher. Throw inside to skip a malformed line. */
  onEvent: (data: T, raw: string, eventType: string) => void
  /** Fires once, after the first server 'connected' named event. */
  onConnected?: () => void
  /** Fires on every state transition. Use it to drive UI badges. */
  onStateChange?: (state: SseState, info: SseStateInfo) => void
  /** Initial backoff. Default 1000 ms. */
  baseDelayMs?: number
  /** Cap on backoff. Default 30 000 ms. */
  maxDelayMs?: number
  /** Hard cap on reconnect attempts. Default Infinity. */
  maxAttempts?: number
  /** Random source for jitter (override in tests). Default Math.random. */
  random?: () => number
  /** Pause retries while tab is hidden. Default true. */
  pauseWhenHidden?: boolean
  /** Reconnect immediately on 'online' event. Default true. */
  reconnectOnOnline?: boolean
  /** Custom EventSource ctor (override in tests). Default globalThis.EventSource. */
  EventSourceCtor?: typeof EventSource
}

export interface SseStateInfo {
  attempt: number          // 1 = first try, 2 = first retry, ...
  nextDelayMs?: number     // set when state === 'reconnecting'
  lastError?: Event        // set when state === 'reconnecting' / 'failed'
  reason?: 'error' | 'closed' | 'online' | 'visible' | 'manual'
}

export interface SseClient {
  close(): void
  reconnect(): void       // force a reconnect, reset attempt counter
  getState(): SseState
  /** Convenience: subscribe to state changes; returns an unsubscribe fn. */
  onStateChange(cb: (s: SseState, info: SseStateInfo) => void): () => void
}

export function createSseClient<T = unknown>(
  opts: SseClientOptions<T>,
): SseClient { /* …see §4.1 */ }
```

### 4.1 Implementation outline (≤200 lines)

- Module-scope `let` state: `es: EventSource | null`, `attempt = 0`,
  `hasBeenOpen = false`, `state: SseState = 'connecting'`,
  `retryTimer: ReturnType<typeof setTimeout> | null`,
  `stateSubs: Set<(s, info) => void>`.
- `emitState(s, info)` updates `state` and fans out to subscribers.
- `start()`:
  - Cancel any pending `retryTimer`.
  - `emitState('connecting', { attempt })`.
  - `es = new EventSourceCtor(opts.url)`.
  - `es.addEventListener('open', …)` — log + (no state change yet,
    server 'connected' is the real signal).
  - `es.addEventListener('connected', …)` — `hasBeenOpen = true`,
    `attempt = 0`, `emitState('open', …)`, `opts.onConnected?.()`.
  - `es.onmessage = (e) => opts.onEvent(parse(e.data), e.data, 'message')`.
  - `es.onerror = (e) => handleError(e)`.
- `handleError(e)`:
  - `es?.close(); es = null`.
  - If `!hasBeenOpen` → this is a 4xx/5xx on the *first* attempt.
    `emitState('failed', { attempt, lastError: e, reason: 'error' })`.
    Do **not** schedule a retry.
  - Else → `attempt++; scheduleRetry({ reason: 'error' })`.
- `scheduleRetry({ reason })`:
  - If `state === 'closed'` return.
  - If `attempt > opts.maxAttempts` → `emitState('failed', …)` and return.
  - If `opts.pauseWhenHidden && document.hidden` → wait for
    `visibilitychange` instead of a timer.
  - `const exp = Math.min(opts.baseDelayMs * 2 ** (attempt - 1), opts.maxDelayMs)`;
  - `const jitter = exp * (0.5 + random() * 0.5);`   // full jitter
  - `retryTimer = setTimeout(start, jitter);`
  - `emitState('reconnecting', { attempt, nextDelayMs: jitter, reason })`.
- `close()`:
  - `emitState('closed', { reason: 'manual' })`.
  - Cancel `retryTimer`, close `es`, remove all DOM listeners,
  - Subscribers get `'closed'` once and that's it.
- `reconnect()`:
  - Cancel `retryTimer`, close `es`, `attempt = 0`, `start()`.
- DOM listeners (registered on construction, removed in `close`):
  - `document.addEventListener('visibilitychange', onVis)`
  - `window.addEventListener('online', onOnline)`
  - `onVis`: if `!document.hidden && state === 'reconnecting'` →
    cancel timer, `start()` immediately.
  - `onOnline`: if `state === 'reconnecting'` → cancel timer, `start()`.

> **Note on the existing JSON-buffer logic.** The four factory functions
> in `api/index.ts` each open-code a `let jsonBuffer = ''` and
> `{`/`}` slicing. That code stays where it is and is moved into the
> `onEvent` callback when we refactor §5. This module does *not* know
> about JSON.

---

## 5. Refactor: `src/apps/desktop/src/api/index.ts`

Each of the 4 `create*` functions becomes a 5-10-line adapter. The
adapter:
1. Hard-codes the URL.
2. Implements `onEvent` with the existing buffer + `{`/`}` slicing,
   dispatching the parsed `data` to the caller's `onEvent` (renamed
   `onMessage` / `onSessionEvent` / `onQueueEvent` / `onWorkerEvent`
   in the public signature).
3. Maps `SseClient` state → caller's existing `onError` callback:
   - `'failed'` (after at least one open) → call `onError(error)`
     so the existing call sites' `console.error` logs still fire.
   - `'open'` → call `onConnected?.()`.
4. Returns the `SseClient` (instead of the raw `EventSource`).

### 5.1 Return type changes

| Function | Old return | New return |
|----------|-----------|-----------|
| `createSseConnection` | `EventSource` | `SseClient` |
| `createSessionsSseConnection` | `EventSource` | `SseClient` |
| `createQueueMessagesSseConnection` | `EventSource` | `SseClient` |
| `createWorkersSseConnection` | `EventSource` | `SseClient` |

All four still expose `.close()`. None of the call sites use any other
`EventSource` member (verified by `rg` — only `.close()` is touched).
The `onerror` / `onopen` / `onmessage` / `addEventListener` members
become internal.

### 5.2 `api/index.ts` exports

Add to the bottom of the file:

```ts
export { createSseClient } from '../helpers/sseClient'
export type { SseClient, SseClientOptions, SseState, SseStateInfo } from '../helpers/sseClient'
```

---

## 6. Call-site updates

### 6.1 `App.vue` (workers)

- `let workersEventSource: EventSource | null = null` →
  `let workersSse: api.SseClient | null = null`.
- Delete the inline `setTimeout(initWorkersSse, 5000)` (the new client
  handles it).
- Subscribe to state in `initWorkersSse()` for the indicator:
  `workersSse.onStateChange(updateSseBadge)`.
- `onUnmounted` → `workersSse?.close(); workersSse = null;`.
- The duplicate "Initial fetch to sync state" inside `onConnected` stays
  (it's a one-shot, not a per-retry sync — and we **want** to re-sync
  after a reconnect, so the API contract here is exactly right: it
  already runs on every reconnect).

### 6.2 `ChatsList.vue` (sessions)

- `const sessionsEventSource = ref<EventSource | null>(null)` →
  `ref<api.SseClient | null>(null)`.
- `onUnmounted` already calls `disconnectSessionsSse()`; nothing else
  to do.

### 6.3 `ChatView.vue` (chat + queue)

- Both `eventSource` and `queueEventSource` refs: type → `api.SseClient | null`.
- The error callback for the **chat stream** (line 1106) currently
  does `isStreaming.value = false; streamingContent.value = ''`.
  That stays. But we need to *not* show "stream ended" during a
  reconnect. Fix: change `isStreaming` to `false` only when
  `info.state === 'failed'` (terminal) — keep the in-flight UI
  intact while `state === 'reconnecting'`.
- The `isAlreadyConnectedSSE` flag becomes:
  - Set `true` on first `onConnected`.
  - Reset `false` only on explicit `disconnectSse()` (i.e. user
    navigates away or unmount).
  - Do **not** reset on transient `reconnecting` / `closed` — that
    is the whole point of the reconnect feature.

### 6.4 `Sidebar.vue`

- Leave the stub alone for this change. It's a no-op and out of scope.

---

## 7. UI feedback (optional, but small)

Add a single `<SseStatusBadge :client="…" />` component that subscribes
to `onStateChange` and renders a tiny pill:

| state | pill |
|-------|------|
| `open` | hidden (default) |
| `connecting` | grey "Connecting…" |
| `reconnecting` | amber "Reconnecting (attempt N)…" |
| `failed` | red "Connection lost — reload?" (with a manual `reconnect()` button) |
| `closed` | hidden |

Place it:
- in the chat header (right side, next to the worker indicator), driven
  by the **chat stream** client.
- in the sidebar / chat-list header, driven by the **sessions** client.
- the workers stream status is already implicit (chat shows
  "processing" when there are workers).

If the badge scope feels too big for this change, drop it and ship the
core reconnect logic without the pill — the `onStateChange` API is
still there for a follow-up.

---

## 8. Tests

### 8.1 New file: `src/apps/desktop/src/__tests__/sseClient.spec.ts`

Use vitest's fake timers + a controllable `EventSourceCtor` mock:

- **Backoff schedule.** With `baseDelayMs=1000, maxDelayMs=30000,
  random=()=>0.5`, after 5 consecutive errors the scheduled delays
  are `[1000, 2000, 4000, 8000, 16000]` (each * 0.75 because jitter
  is `0.5 + 0.5*rand`).
- **Jitter range.** With `random=()=>0`, delays are `0.5 * exp`; with
  `random=()=>1`, delays are `1.0 * exp`.
- **`open` cancels retry.** Trigger error, schedule retry at t=1000,
  fire `open` at t=500, assert no `start()` is called at t=1000.
- **First-error is fatal, mid-stream error is not.** Construct with
  `EventSourceCtor` that fires `error` before any `open` → state
  becomes `failed`, no retry. Construct with one that fires `open`
  then `error` → state becomes `reconnecting`, retry scheduled.
- **`visibilitychange` behaviour.** After an error in the hidden tab,
  advance the timer — assert the retry was *not* fired. Then
  dispatch `visibilitychange` with `document.hidden = false` → assert
  retry fires within a microtask.
- **`online` event.** After an error, dispatch `online` → assert
  retry fires immediately, attempt counter is preserved.
- **`close()` is terminal.** Call `close()` then dispatch
  `visibilitychange` / `online` / fire another `error` from a stale
  ES — assert no further state changes.
- **State emission order.** Subscribe to `onStateChange`, run a
  full connect → error → reconnect → open cycle, assert the emitted
  sequence is exactly
  `['connecting', 'reconnecting', 'connecting', 'open']`.
- **Listener cleanup.** After `close()`, assert
  `document.listeners.length` and `window.listeners.length` are back
  to their pre-construction values (use a small spy on
  `addEventListener` / `removeEventListener`).

### 8.2 Existing tests

- `__tests__/setup.ts` already polyfills `EventSource` as a no-op
  stub. **Extend** it with `static CONNECTING / OPEN / CLOSED`,
  `withCredentials`, and a way to fire synthetic events. Most tests
  import the api module but never call the factory, so the existing
  smoke test in `App.spec.ts` should keep passing without change.

### 8.3 Manual / E2E checklist (run in dev)

1. Start the server, open a chat, send a message — chunks arrive.
2. While streaming, `sudo iptables -A OUTPUT -p tcp --dport 8081 -j DROP`
   (or just hit DevTools → Network → Offline). Within 1 s the badge
   shows "Reconnecting…". Bring network back → within 1 s badge
   disappears, new chunks arrive, message completes.
3. `kill -9` the nalar process, wait 5 s, restart it. The chat list
   re-syncs on reconnect, no manual reload.
4. Switch to another tab for 30 s, switch back — no reconnect storm,
   the timer was paused while hidden.
5. Reload the page while a chat is open — no leaked EventSource
   connections in DevTools → Network (the `onUnmounted` cleanup works).

---

## 9. NALAR.md updates (post-merge)

Add an entry under **Bug Fixes** (the bug we *prevented* in §1.1)
and one under **Lessons Learned**:

```md
- [sseClient.ts] Replaced naive `setTimeout(reconnect, 5000)` in
  App.vue with a centralized auto-reconnecting `SseClient` wrapper
  (helpers/sseClient.ts). Fixes three latent issues: (1) timer leak
  on unmount, (2) the pending timer closing a *working* EventSource
  on a second transient error, (3) zero reconnect logic on the
  ChatsList and ChatView SSE streams. All 4 streams now share
  exponential backoff (1s→30s, full jitter), visibility-change
  pausing, and online-event fast-path. 9 new unit tests in
  sseClient.spec.ts cover backoff schedule, jitter range, open
  cancels retry, first-error-is-fatal, visibility, online, close
  is terminal, and listener cleanup.
```

```md
- **EventSource auto-reconnect needs explicit wiring** — the browser
  EventSource spec *does* have a `retry:` field, but only if the
  server sends it, and only for some failure modes (4xx/5xx and
  `EventSource.CONNECTING` are not retried). Build a small wrapper
  (e.g. helpers/sseClient.ts) that owns the EventSource, the retry
  timer, and the `visibilitychange` / `online` listeners — and
  *cancel* the retry timer on `onopen` so a successful reconnect
  doesn't get killed by a stale timeout.
```

---

## 10. Migration & risk

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Existing `EventSourceStub` in `__tests__/setup.ts` doesn't have the members the new code touches | Low | Extend the stub in the same PR; run `bun run test` first to confirm. |
| ChatView's `isStreaming` flag flips to false on every transient error → user sees "stream ended" repeatedly | Medium | Already addressed in §6.3 — only flip to false on terminal `failed`/`closed`. |
| A 404 (e.g. session deleted) loops forever | Medium | Addressed in §4.1 — first-error-no-open is fatal. |
| Multiple `setTimeout` fire after the user navigates away | Medium | Addressed in §1.1 — all timers are owned by the `SseClient`, cancelled in `close()`. |
| Server-replay of missed events on reconnect duplicates UI messages | Low | Out of scope (NG3). Add a `?since=…` cursor on the server if/when it becomes a real bug. |
| Jitter too aggressive, server flooded with retries after a brief outage | Very low | Min delay is `0.5 * base` = 500 ms with default config; max is 30 s. |

**Rollout order:**
1. Land `sseClient.ts` + tests (§4, §8.1). No call sites change yet.
2. Refactor `api/index.ts` (§5). The 4 functions now return `SseClient`
   but `SseClient.close()` matches `EventSource.close()`, so call
   sites work unchanged.
3. Update call sites (§6) to use the new type and the new state
   channel.
4. Add the badge (§7) if scope allows.
5. Update `NALAR.md` (§9).

Steps 1-3 are the minimum viable change. Step 4 is a separate,
follow-up.

---

## 11. Open questions for the user

1. **Backoff defaults.** Is `base = 1 s`, `max = 30 s` OK for the
   server-restart case? If the server takes longer than 30 s to come
   back, the user has to reload. We could raise the cap to 60 s, but
   that also delays the first signal that something is wrong.
2. **Badge scope.** Include the UI indicator (§7) in this PR, or
   ship the core reconnect first and badge as a follow-up?
3. **`Sidebar.vue` stub.** While we're touching the SSE code, should
   we delete the dead `connectSessionsSse` / `disconnectSessionsSse`
   stubs in `Sidebar.vue` (lines 174-181) and the
   `sessionsEventSource` ref it doesn't use, or leave the cleanup
   for a separate PR?
