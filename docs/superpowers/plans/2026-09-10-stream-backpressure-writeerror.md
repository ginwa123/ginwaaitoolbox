# Fix `scanner.next failed after N chunk(s): WriteError` — streaming backpressure + bounded SSE writes

**Date:** 2026-09-10
**Task:** `task_1789065386812_1` (kanban)
**Branch:** `worktree/chttp-stream-backpressure`
**Symptom (user log):**

```
[Retry 3/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.
Server said: scanner.next failed after 1260 chunk(s): WriteError
```

---

## 1. Where the error string comes from

`Agent.zig:2962` formats it:

```zig
"scanner.next failed after {d} chunk(s): {s}", .{ chunk_count, @errorName(err) }
```

`WriteError` is `custom_http_client`'s `LocalError.WriteError`, mapped from
libcurl's `CURLE_WRITE_ERROR` (`stream.zig` `mapStreamError`). `CURLE_WRITE_ERROR`
means **our own WRITEFUNCTION returned short** — i.e. libcurl did not fail, *we*
aborted it. The workflow then turns any `callDynamicAgentNew` error into
`StreamInterrupted`, saves a retry chat message, sleeps, and re-issues the whole
LLM request — throwing away everything received so far (1260 chunks in the
reported case).

## 2. Root cause — four defects, two modules

### A. A full chunk queue aborted the transfer (`stream.zig`)

`writeCallback` is libcurl's `WRITEFUNCTION`. The old body was:

```zig
const was_empty = state.queue.isEmpty();
if (!state.queue.push(state.allocator, slice)) return 0;   // ← abort!
```

`push` returned `false` for **two very different** conditions:

| condition | meaning | correct reaction |
|---|---|---|
| ring buffer full (`next_tail == head`) | transient backpressure — the consumer is behind | **wait / retry** |
| `allocator.dupe` failed | genuine OOM | abort |

Returning `0` from a WRITEFUNCTION makes libcurl stop the transfer with
`CURLE_WRITE_ERROR`. So a consumer that was merely *momentarily* behind — the
agent thread can block for seconds inside its per-chunk SSE emit — destroyed a
healthy multi-thousand-chunk response.

**Reproduced** (test `stream: stalled consumer does not abort the transfer with
WriteError`, pre-fix behaviour):

```
[default] (warn): curl_easy_perform failed: code=23 msg=Failure writing output to destination, passed 16384 returned 0
stream.next aborted after 0 of 8388608 bytes: WriteError
```

### B. Lost-wakeup race in the same function (`stream.zig`)

`isEmpty()` and `push()` each took the queue lock separately:

```
producer: isEmpty() -> false      (queue held 1 chunk)
consumer: popOne()  -> drains it, re-enters next(), parks on signal_gen
producer: push()    -> succeeds, but `was_empty` is stale-false → NO bump, NO futex wake
```

The consumer then sleeps out its full 300 s budget with a non-empty queue while
the producer keeps pushing — and once the buffer hits `QUEUE_CAPACITY` (64),
defect A fires. This is a *direct* path from "consumer briefly ahead" to
`WriteError`.

### C. `cancel()` was a no-op (`stream.zig`)

`state.cancelled` was written by `cancel()` and **read by nobody**. The comment in
`openStream` claimed "Cancellation now flows through `state.cancelled` being
checked inside writeCallback/headerCallback" — it wasn't. Consequence:
`ResponseStream.deinit()` → `cancel()` → `thread.join()` blocked for up to
`CURLOPT_TIMEOUT_MS` (300 s in production) on a live transfer, and
`stream.cancel()` did nothing.

### D. The trigger: an unbounded blocking SSE write (`sse_manager.zig`)

`stream_callback` (`workflow.zig:1665`) runs **on the agent workflow thread** for
every chunk:

```
Agent.zig scanner loop → callback(ctx, chunk) → stream_callback
  → on_event_sent.sendStreamChunkContent → event_bus.emit("llm", …)   ← SYNCHRONOUS
    → forwardToClients → SseManager.sendToClient
      → self.lock.lock()            ← manager-wide lock
      → writeChunkedFrame → sendAll → blocking send(2), no SO_SNDTIMEO
```

`EventBus.emit` calls the subscriber inline; `sendToClient` holds `self.lock`
across the write; and the SSE client sockets are blocking with **no send
timeout**. So one peer that stopped reading (closed window, suspended machine,
half-open TCP) parks the agent thread *and* the manager lock — every other SSE
emit in the process queues behind it, the agent stops draining the 64-slot chunk
queue, and defect A aborts the stream. That is the whole causal chain.

## 3. Fixes

| # | file | change |
|---|---|---|
| A | `custom_http_client/src/stream.zig` | `writeCallback` now treats `.full` as **backpressure**: 5 ms poll, re-try the same slice, 120 s budget (below libcurl's 300 s timeout so we still report the failure). Returns `0` only on real OOM, `cancel()`, or budget expiry. |
| B | `custom_http_client/src/stream.zig` | `ChunkQueue.push` returns `PushOutcome { pushed: { wake: bool }, full, out_of_memory }`; `wake` ("was the queue empty before this push?") is computed under the **same** lock acquisition as the store. `isEmpty()` deleted. |
| C | `custom_http_client/src/stream.zig` | `writeCallback` samples `state.cancelled` on every backpressure poll → `cancel()`/`deinit()` unblock in ≤5 ms instead of ≤300 s. Stale `openStream` comment corrected. |
| D | `custom_http_server/src/sse_manager.zig` | New `setFdSendTimeout(fd, ms)` applies `SO_SNDTIMEO` (5 s); called from `registerClient` for every SSE socket. A stuck peer now fails its write → existing `send_to_client_failed` path removes it. Best-effort (failures ignored → no behaviour change if the option can't be set). |

Plus a worker-thread sleep helper (`workerSleepNs`) in `stream.zig` — raw
`nanosleep` / Win32 `Sleep`, deliberately **not** `std.Io.sleep` (the libcurl
worker thread owns no Io runtime; see the `monotonicNs` rationale already in the
file).

`SO_SNDTIMEO` gotcha found while probing: the kernel rejects `tv_usec >= 1e6`
with `EDOM` (surfaced as `error.TimeoutTooBig`), so the seconds must go in `.sec`
— `.sec = 0, .usec = 5_000_000` silently fails to apply. `setFdSendTimeout`
splits them correctly and the doc comment records this.

## 4. Tests (every one verified to FAIL without its fix)

`custom_http_client/src/streaming_test.zig` (+ `/flood` fixture emitting 8 MiB,
> 64 × `CURL_MAX_WRITE_SIZE`):

- `stream: stalled consumer does not abort the transfer with WriteError` — the
  exact production reproducer (consumer sleeps 300 ms while libcurl fills the
  queue). **Without fix A: `curl code=23` + `WriteError` after 0 bytes.**
- `stream: cancel() unblocks a worker parked on a full queue` — deinit must
  return < 10 s. **Without fix C it takes the 60 s curl timeout.**

`custom_http_client/src/stream.zig` (inline — `ChunkQueue` is file-private):

- `ChunkQueue.push wake flag is true only on the empty -> non-empty edge`
- `ChunkQueue.push reports .full instead of dropping the chunk`

`custom_http_server/src/sse_manager_test.zig`:

- `sse: setFdSendTimeout bounds a write to a peer that never reads` — writes
  8 MiB into a socketpair nobody reads. Runs the write on a **detached** thread
  with a 10 s watchdog so a regression FAILs instead of hanging CI.
  **Without fix D: `SendNotBoundedByTimeout` after 10 s.**
- `sse: registerClient applies the send timeout to every SSE socket` — static
  contract. **Without fix D: `RegisterClientMissingSendTimeout`.**

## 5. CI coverage note

CI runs only the root `zig build test`. The custom_http_client package suite
(`cd src/modules/custom_http_client && zig build test`) is **not** part of it —
that gap is pre-existing. The SSE suite, by contrast, *can* run in the parent, so
`src/root.zig`'s test block now imports `sse_manager_test.zig` (it is std-only +
the module's local `test_helpers.zig`, no `custom_http_server` module import
needed). It was previously only reachable through the module's own build, which
currently fails to compile for unrelated reasons (`websocket_frames.zig:253`).

## 6. Follow-ups (not in this PR)

- **Wire the custom_http_client package suite into CI** — its 56 tests never run
  in the pipeline today. Fixing `websocket_frames.zig:253` would also let
  `custom_http_server`'s own suite run again.
- **Consider decoupling the SSE fan-out from the agent thread.** Fix D bounds the
  damage (5 s per stuck peer, then the peer is dropped); the structural fix is to
  never do UI socket I/O on the workflow thread at all.
- `BACKPRESSURE_MAX_WAIT_NS` (120 s) is a magic number; if stalls are still seen
  in the wild, make it configurable alongside `read_timeout_ms`.
