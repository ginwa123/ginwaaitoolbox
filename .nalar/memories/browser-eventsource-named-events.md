# Browser EventSource — Named Events Must Be Pre-Registered

The browser-native `EventSource` dispatches a server-sent `event: <name>` line ONLY to
listeners registered for that exact name via `addEventListener('<name>', ...)`. There is
no "catch-all" or "dispatch all named events" API. The default (unnamed) `message` event
is the only one that gets auto-routed to listeners registered with `addEventListener('message', ...)`.

## Symptom

Server-sent events appear in the browser's **Network tab** (the wire format is correct:
`event: foo\ndata: {...}\n\n` reaches the browser), but they **never reach the JS handler**.
Only events without an `event:` line (the default `message` event) ever show up in
`onEvent`/`onmessage`. The handler can see heartbeats, pings, and unnamed events
just fine, but every named event is silently lost.

## Why

`EventSource.addEventListener('queue_message', cb)` is required. If the SseClient (or
your wrapper) only ever calls `addEventListener('message', ...)` and
`addEventListener('connected', ...)`, the JS code can never receive
`event: queue_message` / `event: worker_event` / etc. — regardless of how the server
emits them.

This bites SSE wrapper designs that try to be "generic" by only handling the default
`message` event. The design *promises* to pass through named events (the docstring
typically says "eventType is the named event like `'connected'` / `'queue_message'`"),
but the implementation only registers listeners for `'message'` and one special name,
and the rest of the contract is silently broken.

## Fix

The wrapper must let the consumer declare which named event types it wants to receive,
and register an `addEventListener` for each. A minimal contract:

```ts
createSseClient({
  url: '/api/...',
  onEvent: (raw, eventType) => { /* 'message' | 'connected' | 'queue_message' | … */ },
  // Tell the wrapper which CUSTOM named events to listen for.
  // 'connected' and 'message' are always handled — don't list them.
  additionalEventTypes: ['queue_message', 'worker_event'],
})
```

The wrapper registers `instance.addEventListener(name, ...)` for each entry, dispatches
to `onEvent(raw, name)`, and re-registers them on every reconnect (the EventSource is
rebuilt by retries, so listeners on the previous instance are gone).

## Related: Heartbeat Filter

A similar "server protocol detail leaks into the consumer" issue is the heartbeat.
Backends typically send `data: ping\n\n` (or `data: :keepalive\n\n`) as a keepalive
so proxies / NATs don't close the connection. This arrives as a default `message`
event with `raw === "ping"`, which is noise to the consumer and can grow an
unbounded JSON buffer (because `"ping"` has no `{` or `}` to anchor a slice).

The wrapper should filter it by default — `heartbeatData: 'ping'` is the convention in
this codebase (see `sse_manager.zig` `sendHeartbeat`). Consumers can opt out with
`heartbeatData: null`.

## When This Bites

- Any SSE wrapper that exposes a generic `onEvent(raw, eventType)` API.
- Any time the server emits named events and the consumer never sees them but
  the wire format is clearly correct.
- Heartbeats (or other keepalives) being mistaken for real data, causing
  ever-growing buffers and CPU waste in consumers that JSON-buffer.

## How to Test for This

After wiring up any new SSE consumer, simulate the server-side wire format
exactly (including the `event: <name>` line) and assert the consumer's
`onEvent` was called with `eventType === '<name>'`. Don't just test the
default `message` event — that's the one case that works by default.
