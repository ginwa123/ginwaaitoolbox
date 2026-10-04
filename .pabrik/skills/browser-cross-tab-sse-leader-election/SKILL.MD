---
name: browser-cross-tab-sse-leader-election
description: "How to make browser SSE/WebSocket apps survive many tabs — elect ONE leader tab that owns the connection and fan events out over BroadcastChannel, with the ranking/handover/resync rules that avoid two leaders and stale tabs."
---
---
name: browser-cross-tab-sse-leader-election
description: How to make browser SSE/WebSocket apps survive many tabs — elect ONE leader tab that owns the connection and fan events out over BroadcastChannel, with the ranking/handover/resync rules that avoid two leaders and stale tabs.
tags: [pattern, frontend, sse, browser, architecture]
---

## When to Use

A browser app holds a long-lived stream (`EventSource`/WebSocket) **per window** and
users open many tabs. Browsers cap HTTP/1.1 connections per origin at **6**, so the
7th tab gets nothing and every tab's ordinary `fetch` competes for the remaining
slots. Also use when a reviewer proposes "HTTP/2 will fix it" — it will not:
browsers only speak h2 over **TLS + ALPN**, never h2c.

## Context

* `BroadcastChannel` is per **browser profile**, not per machine or per browser:
  the desktop webview and a Chrome tab are separate processes and will each lead
  their own profile. That is exactly where the 6-connection cap lives, so nothing
  is lost — but do not promise cross-browser sharing.
* `BroadcastChannel` does not echo to the sender, delivery is asynchronous, and
  payloads are structured-cloned (so JSON SSE payloads are fine; wrap
  `postMessage` in try/catch for non-cloneable data).
* Support: Chrome 54+, Firefox 38+, Safari 15.4+, WebView2/WKWebView — always keep
  a solo fallback for engines that lack it.

## Procedure

1. **Rank candidates with a TOTAL order**, never a single number:
   `visible` first, then older `startedAt`, then `tabId` string compare. A numeric
   rank ties when two tabs are created in the same millisecond and both stay
   leaders (two connections — the bug this rule exists to prevent).
2. **Claim first, step down on conflict.** Announce `claim`/`beat` with the rank
   tuple; on hearing a peer that outranks you, step down (close your client). This
   keeps the single-tab path synchronous (no election delay before the first
   EventSource), at the cost of a task-tick overlap when two tabs open together.
3. **Let a visible tab preempt a hidden leader** — hidden tabs are frozen/throttled
   by the browser, so a hidden leader stalls the whole profile. Trigger the
   preemption both on join (seeing a hidden leader's beat) and on
   `visibilitychange → visible`. Skip the "someone may have claimed while I waited"
   re-check for preemption (a hidden leader keeps beating, so that check always
   vetoes it).
4. **Handover:** announce `down` **before** flipping your own closed flag (posting
   after is a silent no-op), and use `pagehide` for real navigation. Replace a
   leader that vanishes silently after a heartbeat timeout (3 beats) — but require
   the taker to be **visible**; a throttled hidden tab makes a worse leader.
5. **Add a resync signal.** Fan-out cannot fix lost deliveries. Emit a coalesced
   "you may be stale" callback when (a) you take over the connection (the handover
   gap reached nobody) and (b) you return from being hidden longer than ~5 s
   (frozen tabs skip deliveries *and* rendering). Subscribers re-fetch from the
   REST API — every tab can call the API directly, whoever holds the stream.
   Coalesce (≥5 s) so window switching cannot stampede the API.
6. **Keep the old path byte-identical** when sharing is unavailable, and make the
   mode injectable (`'auto' | 'on' | 'off'`) so tests can force a path.

## Pitfalls

* **Test environments leak `BroadcastChannel`.** jsdom environments still expose
  Node's `BroadcastChannel`, so a naive `typeof BroadcastChannel === 'function'`
  gate sends every existing suite down the asynchronous election path and breaks
  hundreds of assertions. Resolve `'auto'` to **off** under test
  (`import.meta.env.MODE === 'test'`) and have sharing tests opt in explicitly.
* **Do not `await` a fixed sleep for handover assertions.** Watchdog re-arm means a
  takeover can take up to two timeout periods; poll with a deadline
  (`waitFor(() => isLeader(), 600)`) instead of `settle(ms)`, which becomes flaky
  under parallel test load.
* **Simulate multiple tabs in-process** with a fake channel hub (same-name
  instances deliver to each other, never to the sender, asynchronously) plus a
  `kill()` that drops a participant WITHOUT announcing anything — that is how you
  test the silent-death path.
* Duplicated events are worse than none if the UI is not idempotent — assert in
  tests that the leader never receives its own message and that followers receive
  exactly one copy.
* With 10 tabs, if EVERY tab is hidden the stream pauses (nobody is looking). The
  first tab to become visible must take over *and* resync; do not treat the pause
  as a bug.

## Verification

* Two "tabs" started simultaneously converge on exactly ONE leader and stay
  converged (assert again after a delay, or a tie that re-claims will flap).
* Closing the leader hands over within a jitter; killing it silently hands over
  after the timeout; a hidden follower never takes over.
* A follower's listeners fire once per leader-side event, in order.
* Resync fires on takeover and on long-hide return, is coalesced, and stops after
  unsubscribe; with sharing off it never fires.
* Manual: DevTools → Network shows exactly ONE pending `events` request with
  several tabs open; close the leader and the stream moves.

