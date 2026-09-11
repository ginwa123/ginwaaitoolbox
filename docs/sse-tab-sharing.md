# One SSE connection across every tab

## The problem

Browsers cap HTTP/1.1 connections per origin at **6** (Chrome, Firefox). The app's
SSE bus opened **one `EventSource` per window**, so:

* with 7+ tabs open, the last tabs got **no live updates at all**, and
* every tab's ordinary `fetch` calls competed for the remaining slots, because a
  parked SSE stream permanently occupies one.

Browsers only speak HTTP/2 over **TLS + ALPN**, so cleartext h2c (what
`custom_http_server` now supports) does not change the *browser's* connection
budget for the desktop app's `http://127.0.0.1` origin.

## The fix

Exactly **one** tab ("the leader") owns the `EventSource`. The others are
"followers" and receive every dispatched event over a `BroadcastChannel`
(structured-clone fan-out). Result: **1 connection regardless of tab count**,
leaving 5 slots for the API calls.

```
server ──1 EventSource──▶ leader tab ──BroadcastChannel──▶ N−1 follower tabs
                              │                                    │
                              └────── dispatch() into the same listener maps ──┘
```

## Files

| File | Role |
|---|---|
| `src/apps/desktop/src/helpers/sseTabChannel.ts` | Leader election + fan-out + resync signalling (transport/app agnostic) |
| `src/apps/desktop/src/helpers/sseBus.ts` | Uses the coordinator; opens the client only when leading; `bus.onResync` |
| `src/apps/desktop/src/stores/kanbanSse.ts` | `bus.onResync` → `fetchInitialKanban` |
| `src/apps/desktop/src/stores/designSse.ts` | `bus.onResync` → `fetchInitialDesign` |
| `src/apps/desktop/src/components/views/ChatView.vue` | `bus.onResync` → `loadChatHistory` |

## Leadership rules

* **Rank (total order):** visible beats hidden → older tab beats newer → `tabId`
  breaks the tie. A single numeric rank is *not* enough: two tabs created in the
  same millisecond tie and both stay leaders (two connections).
* **Visible preempts hidden.** Background tabs get frozen/throttled by the
  browser, so a hidden leader cannot serve the profile reliably. A visible tab
  claims as soon as it sees a hidden leader.
* **Handover.** `close()` (and `pagehide`) broadcasts `down` *before* tearing
  down; the remaining tabs elect with jitter. A leader that vanishes silently is
  replaced after `leaderTimeoutMs` (3 s) — but only by a **visible** tab, because
  a throttled hidden tab would be a worse leader.
* **Fallback.** No `BroadcastChannel` (old engine, restricted context, or a
  `channelFactory` that throws) → this tab runs solo, exactly like before.

## Correctness: what every tab sees

* Every event the leader receives is forwarded and dispatched through the **same**
  listener maps on every tab, so all tabs update identically (each tab still
  filters `llm`/`queue` by `session_id` client-side).
* No duplicates (a tab never receives its own message) and ordering is preserved
  (the leader is the only sender).
* **Resync (`bus.onResync`)** covers the two cases where deliveries are *lost*,
  which no amount of fan-out can fix:
  1. **Taking over** the connection — events emitted during the handover gap
     reached nobody.
  2. **Returning from a long hidden period** (> 5 s) — the tab was frozen and
     skipped deliveries *and* rendering.
  Both trigger an idempotent re-fetch from the REST API (every tab can talk to
  the API directly, whoever holds the SSE stream). Coalesced to at most one per
  5 s so window switching can't stampede.

## Boundaries

* **Per browser profile.** `BroadcastChannel` does not cross browsers or profiles:
  the desktop webview and a Chrome tab are separate processes, so each is its own
  leader (2 connections — still fine), and Chrome never shares with Firefox.
  That is exactly where the 6-connection limit applies, so nothing is lost.
* **A discarded tab** (Chrome memory saver) reloads on return and fetches fresh
  state; it rejoins as a follower.
* **Hidden everywhere.** If every tab is hidden, updates pause (nobody is looking);
  whichever tab becomes visible takes over and resyncs.

## Verifying by hand

1. `pnpm dev`, open the app in 2-3 tabs.
2. DevTools → Network → filter `events`: exactly **one** `events?channels=…`
   request is pending; the other tabs show it in the console as
   `[sseTabChannel] became leader (…)` / nothing.
3. Act on kanban in one tab → all tabs update.
4. Close the leader tab → within a jitter the remaining one logs
   `became leader (leader stepped down)` and the stream moves to it.
5. Leave a tab hidden > 5 s, come back → it re-fetches (no stale view).

## Tests

```bash
cd src/apps/desktop
pnpm vitest run src/__tests__/sseTabChannel.spec.ts \
                src/__tests__/sseTabSharing.spec.ts \
                src/__tests__/sseTabResync.spec.ts
```

`src/__tests__/fakes/fakeTabChannel.ts` is an in-process `BroadcastChannel` hub
(multi-tab simulation: async delivery, no self-echo, `kill()` for a tab that
vanished without announcing anything).

The existing SSE suites stay on the legacy path because `tabSharing: 'auto'`
resolves to **off** under vitest (`import.meta.env.MODE === 'test'`) — jsdom
leaks Node's `BroadcastChannel`, which would otherwise push every suite onto the
asynchronous election path. Tests that exercise sharing pass `'on'` explicitly.
