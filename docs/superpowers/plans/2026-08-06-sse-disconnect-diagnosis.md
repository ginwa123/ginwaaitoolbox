# 2026-08-06: SSE disconnect diagnosis — classify every disconnect

**Task**: task_1785608409075 (sse reconnecnting issues)
**Status**: merged on `worktree/sse-disconnect-diagnosis`
**Commit**: `5fa8dc05` (code) + `2b8d2f22` (docs)

## User problem

> make the error better !!!, because i dont know why the sse reconnecint,
> it is from backend or frontend trhat disconnection connection ??

User pasted a log snippet showing:
- Heartbeats flowing every 5s
- `STALL DETECTED` at 7s (readyState=OPEN, lastEventKind=heartbeat)
- `EventSource raw error` at 19s (readyState=CONNECTING, sinceLastEventMs=19296)
- `scheduleRetry set` with 21s delay
- `[connectSse]` called twice for two different sessions

The disconnect was real but the operator couldn't tell whether it was the backend, the frontend, or the network.

## Root cause

The SSE client's diagnostic logs (introduced in the 2026-07-04 "drops at 15s" chunk) surface enough raw data to diagnose the disconnect, but the operator has to cross-reference 2-3 log lines and reason about the signals themselves. The fields are spread across:

- `STALL DETECTED` (logs sinceLastEventMs, lastEventKind, readyState, navConn)
- `EventSource raw error` (logs sinceLastEventMs, lastEventKind, readyState)
- `state` transitions (logs attempt, reason, nextDelayMs)

There's no field that says "this is the backend's fault" or "this is the network's fault".

## Approach

Add a one-shot **DISCONNECT DIAGNOSIS** log that fires after the browser's `error` event and aggregates every signal we have into a single line, with a `suspect` field that classifies the disconnect into one of five buckets:

| Bucket | Meaning | Detection rule |
|---|---|---|
| `backend` | Server stopped sending data while TCP socket was alive | readiness=OPEN AND sinceLastEventMs > 5s |
| `network` | OS-level network drop | navigator.onLine === false |
| `browser` | Tab hidden during silence | document.hidden became true during the silence window |
| `user-code` | User code called close()/reconnect() recently | sinceLastCloseMs or sinceLastReconnectMs < 5s |
| `unknown` | Signals conflict | (fallthrough) |

Each bucket also gets a `conclusion` field — a human-readable sentence with the suspect label verbatim, so the operator can grep for `conclusion: ...backend...` to find every disconnect the desktop app attributed to the server.

## Why not auto-reconnect on STALL DETECTED?

The stall detector currently only logs. We could close() the dead EventSource + start() a fresh one the moment the stall fires, instead of waiting 12s for the browser to catch up. But:

- The user's question is "make the error better" — better diagnostics, not faster reconnection
- Auto-reconnect on stall would mask the real cause (e.g. a misconfigured proxy that drops the connection every 5 minutes)
- The current `attempt 1` retry delay is already 750ms-1s (before the exponential kicks in)
- The fundamental problem ("19s of silence before reconnect") is on the server side; the client-side heuristic fix would be a hack

So: keep the stall detector as a logging-only diagnostic, but make the LOGS so clear that the operator can act on the diagnosis without guessing.

## Per-bucket examples

**`backend`** (most common in production):
```
[sse-client] DISCONNECT DIAGNOSIS {
  "suspect": "backend",
  "reason": "error-event",
  "readiness": "OPEN",
  "navigatorOnline": true,
  "effectiveType": "4g",
  "tabHiddenAtMs": null,
  "sinceLastEventMs": 19296,
  "lastEventKind": "heartbeat",
  "wasStalledBefore": true,
  "stallToErrorMs": 12000,
  "conclusion": "Suspect=backend: server stopped sending events 19s ago (last was heartbeat); TCP socket was open so backend is the prime suspect"
}
```

**`network`**:
```
[sse-client] DISCONNECT DIAGNOSIS {
  "suspect": "network",
  "navigatorOnline": false,
  ...
  "conclusion": "Suspect=network: browser reports navigator.onLine === false; TCP socket likely dead after 8s of silence"
}
```

**`user-code`** (intentional close):
```
[sse-client] close() called {"reason": "page-unload", "caller": "pagehide|beforeunload"}
...
[sse-client] DISCONNECT DIAGNOSIS {
  "suspect": "user-code",
  "lastCloseReason": "page-unload",
  "conclusion": "Suspect=user-code: user code called close()/reconnect() (reason=\"page-unload\") within the last 5s — disconnect is intentional"
}
```

## Why capture the readiness at stall time?

The browser transitions `readyState` from OPEN (1) to CONNECTING (0) during its internal retry cycle. By the time the browser fires the `error` event, the readiness is already CONNECTING (0) — losing the smoking gun ("TCP was alive during the silence"). Capturing `stallFiredAtReadiness` at stall time and replaying it at diagnosis time preserves the smoking gun.

Verified for the user's report: at STALL DETECTED, `readyState=1 (OPEN)`. At error event, `readyState=0 (CONNECTING)`. The diagnosis uses `OPEN` correctly.

## What changed

### `src/apps/desktop/src/helpers/sseClient.ts`

- Added module-level `getCallerStack()` helper for capturing close()/reconnect() call sites
- Added closure-level `tabHiddenAtMs`, `navigatorOfflineAtMs`, `lastCloseReason/Caller/AtMs`, `lastReconnectReason/Caller/AtMs`, `stallFiredAt`, `stallFiredAtReadiness`, `constructedAtCaller`
- Added `classifyDisconnectSuspect(snapshot)` and `formatConclusion(suspect, snapshot)` helpers
- `close(reason?: string)` and `reconnect(reason?: string)` signatures widened with optional reason
- `onVisibilityChange` now tracks `tabHiddenAtMs`
- Added `onOffline()` listener
- `onPageHide()` now sets `lastCloseReason = 'page-unload'` before teardown
- `resetStallDetector()` enriched `STALL DETECTED` log with suspect + conclusion + network + visibility state
- EventSource 'error' listener enriched with `navigatorOnline`, `wasStalledBefore`, `stallToErrorMs`, `tabHiddenAtMs`
- New `logDisconnectDiagnosis(reason)` function fires before `scheduleRetry`
- `handleError` calls `logDisconnectDiagnosis` on every error path (initial open, retryable, exhausted)
- `connectedEventName` listener resets `stallFiredAt` and `stallFiredAtReadiness` on every reconnect

### `src/apps/desktop/src/helpers/sseBus.ts`

- `reconnectGlobal()` calls `_globalClient?.reconnect('user-clicked-retry-or-bus-reconnect')`
- `close()` calls `gc.close('bus-torn-down')`

### `src/apps/desktop/src/__tests__/sseClient.deeplog.spec.ts`

- 6 new tests (was 7, now 13)
- 3 mock-test fixes:
  - `parseLogCalls` regex widened from `\] (\w[\w ]*?)` to `\] (.+?)` to capture `()` in messages
  - Mock EventSource now fires both `addEventListener('error', ...)` AND `onerror` handlers (real browser dual-fire)
  - `simulateOpen()` sets `readyState=1` (matches real browser)
  - `beforeEach` polyfill now includes `navigator.onLine: true`

## Out of scope

- **Backoff schedule**. The 21s retry delay is unchanged. The user asked about diagnostics, not timing.
- **Auto-reconnect on STALL DETECTED**. Documented above — fixing the cause (server) is the right answer.
- **UI surface for the suspect**. The user wants log-line diagnostics (not a badge).
- **Server-side stall detection**. The current server-side sweep (`sweepStaleClients`) only reaps dead clients; it doesn't proactively log "my heartbeat has stopped sending".

## Verification

- `vue-tsc --build` clean
- `bunx vitest run src/__tests__/sseClient.deeplog.spec.ts` — 13/13 pass
- `bunx vitest run` full suite — 1963 pass, 12 fail (the 12 are pre-existing on main: `DesignView.undoHidden ×5`, `DesignElement static ×1`, `nudge clamp ×1`, `AppLayout.translateResize ×1`, `AppLayout.memoriesGate ×4`)
- Live demo test (deleted) showed the new logs answering the user's question end-to-end:
  - `STALL DETECTED {suspect: "backend", conclusion: "Suspect=backend: server stopped sending events 7s ago (last was heartbeat); TCP socket was open so backend is the prime suspect"}`
  - `EventSource raw error {wasStalledBefore: true, stallToErrorMs: 12000}`
  - `DISCONNECT DIAGNOSIS {suspect: "backend", wasStalledBefore: true, stallToErrorMs: 12000, conclusion: "Suspect=backend: server stopped sending events 19s ago (last was heartbeat); TCP socket was open so backend is the prime suspect"}`

## Risk

**Low.** The changes are purely additive:
- New optional `reason?` parameter on `close()` and `reconnect()` (backward compatible)
- New fields in existing logs (existing tests still parse them — they only check subsets)
- New `DISCONNECT DIAGNOSIS` log fires ONCE per error event (no perf impact)
- New `offline` listener fires only when the browser does (rare)

The classifier is too simple to break: 5 buckets, 5 priority rules, no async, no Memory.

## Follow-ups (for the next task)

1. Server-side heartbeat stall detection — log "last heartbeat sent X seconds ago" when the connection appears stale
2. Auto-reconnect on STALL DETECTED — graceful close + fresh EventSource, but only if `stall-then-error` happens N times in a row (heuristic)
3. UI surface — add a "Disconnected" badge that shows the `suspect` field on hover
4. Frontend metric collection — emit `DISCONNECT_DIAGNOSIS` events to the frontend log client so the operator can grep server-side
