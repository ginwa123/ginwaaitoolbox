# nalar desktop — `net::ERR_INCOMPLETE_CHUNKED_ENCODING` and SSE auto-reconnect

`net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` is a Chromium-level network
error. The server started sending a chunked HTTP response (status 200,
`Transfer-Encoding: chunked`) but the TCP connection was terminated
**before the terminating `0\r\n\r\n` chunk arrived** — so the browser
couldn't decode the stream as complete chunked encoding.

## What triggers it

- The `nalar` server process died mid-stream (SIGKILL, OOM, segfault).
- A Zig `connection.close()` (or equivalent) before all SSE bytes were
  flushed to the kernel. The browser sees a half-open HTTP response.
- A network drop (Wi-Fi loss, proxy timeout, load balancer idle
  reaper) that closes the TCP socket without a clean FIN.
- Server panic / unhandled error in the handler that's about to write
  the final chunk.

The `(OK)` in the error message means the **HTTP status line was 200**
— the connection completed the headers and started streaming. The
"incomplete chunked" part means the **body framing was never closed
properly**.

## What `sseClient.ts` does with it

The `ERR_INCOMPLETE_CHUNKED_ENCODING` surfaces to JS as an
`EventSource.onerror` event. The `SseClient` handles it via
`handleError` (sseClient.ts:555):

1. **Closes the dead `EventSource`** so it can't fire `onerror` again
   (browsers fire it on every internal retry attempt — we want exactly
   one error → one attempt counter increment).

2. **First-attempt fatal path** (sseClient.ts:575): if the connection
   never received the server's `connected` named event, the state
   transitions to `'failed'` immediately — no retry. The first attempt
   failing is treated as "URL wrong / 4xx / 5xx / construction error".

3. **Transient-error path** (sseClient.ts:587): if the connection was
   previously `'open'` (we got the `connected` event), the state
   transitions to `'reconnecting'` and a retry is scheduled with
   exponential backoff (1 s → 30 s, full jitter, AWS pattern). The
   `connected` event handler increments the attempt counter and the
   timer fires `start()` again with a fresh `EventSource`.

The `ChatView.vue` `onError` callback (line 1579) only fires on the
**terminal `'failed'` state** (see `api/index.ts:742` —
`onStateChange` only invokes the caller's `onError` when
`state === 'failed'`). So during a successful auto-reconnect cycle,
`isStreaming.value` stays `true` and the UI keeps showing the
streaming placeholder. This is correct — a transient drop should not
make the UI claim the stream ended.

## Limitation for the LLM stream specifically

The `/api/llm/stream/<session_id>` stream is **one-shot per message**:
the LLM produces chunks until `finish_reason` arrives, then the
server closes the stream. If the TCP connection drops mid-message,
auto-reconnecting **does not retrieve the partial response** — the
server's LLM call has already returned or crashed, and the SSE stream
is not resumable from byte offset N (the SSE spec does not support
stream resumption; the only protocol-level reconnect hint is the
`retry:` field, which `sse_manager.zig` does not emit).

So a reconnect after a mid-stream drop will typically result in:
- A fresh `EventSource` opens
- The server emits a `connected` named event
- The server then has no in-flight generation for that session →
  the stream is effectively "stuck" or returns an error event
- `ChatView` sees no more chunks and `isStreaming` stays true until
  the server-side timeout fires or the user navigates away

**Fix to consider (out of scope here)**: backend could track
"in-flight generation" state per session and emit a synthetic
`finish_reason: 'stream_interrupted'` event when a reconnected client
attaches to a session whose LLM call already finished. Without that,
the user has to re-send the message to recover.

## How to verify auto-reconnect is working

1. Open DevTools → Network → filter by "stream".
2. Watch the `/api/llm/stream/<session_id>` request.
3. Either:
   a. Stop the `nalar` process mid-generation (`kill <pid>`). The
      request goes red with `ERR_INCOMPLETE_CHUNKED_ENCODING`.
      Within ~1–30 s a new request with the same URL appears
      (same path, different connection — `EventSource` is rebuilt).
   b. Block the port with `iptables -A OUTPUT -p tcp --dport 8081 -j
      DROP` for 5 s, then unblock. A new stream appears.
4. The status badge in the chat (`SseStatusBadge.vue`) should briefly
   show "Reconnecting…" during the gap, then clear once the new stream
   receives `connected`.

If the badge instead goes straight to "Connection lost", the
auto-reconnect failed — likely because the server is genuinely down
and the SseClient exhausted `maxAttempts` (default `Infinity`, so this
shouldn't happen unless explicitly capped).

## When this bites

- Any user-visible "stream died mid-message" report.
- Server restarts during active LLM generation (every backend code
  reload on port 8081 will kill the stream of any user currently
  streaming).
- Network drops, VPN reconnects, sleep/wake on laptops.
- The current `disconnectSse()` in ChatView.vue (line 1612) clears
  `isStreaming.value = false` and the streaming bubble — but only on
  terminal failure. During a successful reconnect the bubble stays
  visible, which is the right behavior, but the user may see the
  spinner "stuck" if the backend doesn't emit a recovery event.

## How to test in isolation

```bash
# Terminal 1: start nalar on 8080
./zig-out/bin/nalar --port 8080

# Terminal 2: open chat, start a long generation (e.g. a coding
# task that takes 30s)

# Terminal 3: mid-stream, kill nalar
kill $(pgrep -f "nalar --port 8080")

# Result: browser console shows ERR_INCOMPLETE_CHUNKED_ENCODING,
# then a new /api/llm/stream/<id> request appears within the
# backoff window. UI state depends on backend recovery.
```