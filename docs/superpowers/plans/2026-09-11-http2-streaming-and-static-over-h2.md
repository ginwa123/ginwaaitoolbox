# HTTP/2 streaming + static over h2 — the two things left before `https://` works for the UI

> **Status: PLAN FOR REVIEW.** Follows `2026-09-11-http2-custom-http-server.md` (h2c, #449)
> and `2026-09-11-http2-tls-alpn.md` (TLS + ALPN, #449 `62a0f2ef`).
> Read §0 (decisions) and §1 (why the order matters) before executing.

**Goal:** make the desktop UI work over `https://127.0.0.1` — i.e. close the last two
phase-1 gaps so a browser/webview that ALPN-negotiated `h2` can load its assets and
receive live updates.

**Why now:** TLS + ALPN already works (`curl -k --http2 https://…/health` → `2`,
`--http1.1` → `1.1`, verified). But once ALPN picks `h2` the browser uses h2 for
**every** request on that origin, and today:

* **SSE over h2 → `501`** (and over h1+TLS too — the SSE manager writes chunked
  frames straight to the socket). Live updates die.
* **Static files over h2 → `404`** (h1+TLS static works — verified `/app.css` → 200).
  The webview loads no assets at all.

**Architecture:** (1) give `SseManager` a transport-neutral sink so the same SSE
broadcast machinery can emit h1-chunked *or* h2 DATA frames; (2) give the h2 driver a
streaming API (HEADERS-without-END_STREAM + window-aware DATA + a wake path so a
writer on another thread can push frames while the connection task is blocked in
`read`); (3) let the app supply an h2-shaped static responder (the module cannot
import `src/static_files.zig` — outside its package path); (4) only then flip the
webview to `https` behind a flag.

---

## 0. Decisions to approve

### D1 — One `SseSink` abstraction (recommended) vs a second h2-only SSE path

`SseManager` (≈1000 lines, heavily byte-level tested) writes through
`writeChunkedFrame(fd, data)` (`sse_manager.zig:893`) → `sendAll(fd, …)`
(`:912`), and terminates with `0\r\n\r\n` on **four** removal paths
(`:287`, `:305`, `:422`, `:673`) plus `sendTerminatingChunk` (`:878`).

| Option | Cost |
|---|---|
| **`SseSink` vtable, h1 impl first (recommended)** | One refactor; the h1 path keeps producing byte-identical frames (existing tests are the guard); the h2 path is a second impl; SSE-over-**h1+TLS** also gets fixed for free (the h1 sink writes through `Stream`, not a raw fd). |
| A separate h2-only SSE code path | Duplicates heartbeat/broadcast/sweep/queueing logic in a second place — the kind of divergence that rots. Rejected. |

**Recommendation: the sink.** Phase it so the *first* commit is a pure refactor with
zero behaviour change (all existing SSE tests green), and the h2 impl lands second.

### D2 — Wake mechanism for h2 DATA writes: per-connection notify pipe (recommended)

The h2 connection task is single-threaded and blocks in `read` (`http2/server.zig`
`serveConnection`); SSE writes come from `SseManager`'s heartbeat/broadcast threads.
The connection must be woken to flush.

| Option | Trade-off |
|---|---|
| **Per-connection notify pipe + poll (recommended)** | Immediate delivery (sub-ms), and the repo already has this exact pattern inside `SseManager` (`notify pipe` `:325-330`, `drainPipeNonBlocking` `:357-374`, `posix.poll` `:565`). Cost: the h2 read loop must become poll-based (POSIX `poll`; Windows has no `poll` — see D2b). |
| Periodic flush (`poll` with a 25–100 ms timeout, no pipe) | Simpler, no pipe; every event pays up to the timeout in latency. Chat token streaming would visibly stutter. Acceptable as a fallback only. |

**D2b (same decision, one line):** the Windows branch must use a sleep/timer poll
(`WSAPoll` does not work on sockets that aren't SOCKET handles in our wrapper), which
is exactly how `sse_manager.zig:503-530` forks today. Ship Linux/macOS first, keep
Windows on the timeout path, and say so.

**D2c — the TLS trap:** when polling, the fd can be readable *and* OpenSSL can still
hold buffered plaintext from an earlier record. The loop must check
`SSL_pending()` first and drain it before polling, or a paused connection can stall
with data already in the buffer. (Expose `Conn.pending()` from `tls.zig`.)

### D3 — Static over h2: an app-provided `static_h2_handler` (recommended)

The module cannot import `src/static_files.zig` (outside its package path — Zig
rejects it), and the existing `static_dir_handler` writes a complete **HTTP/1.1**
response to a `Stream`.

**Recommendation:** add an optional second callback to `GinwaServer`:

```zig
/// h2-shaped static responder: fill (status, headers, body) instead of writing
/// bytes, so the module stays free of any static-file knowledge.
static_h2_handler: ?*const fn (
    cfg: *const anyopaque,
    allocator: std.mem.Allocator,
    request_path: []const u8,
    out: *StaticResponse,   // { status: u16, headers: []const HeaderPair, body: []const u8 }
) anyerror!void = null,
```

`src/main.zig` implements it by reusing the *resolution* logic it already has
(`writeStaticFileResponse` minus the wire formatting), reading the file into the
arena and returning status/headers/body. The h2 dispatcher calls it on a route miss
and writes a normal `respond(...)`. Static bodies are memory-buffered, so this is a
`Content-Length`-shaped response — no streaming needed for phase 1 (`--static-dir`
assets are small; the existing h1 path buffers them too).

### D4 — Backpressure policy for SSE over h2 (must be decided, not drifted into)

An SSE producer can outrun a slow client's flow-control window. `queueData` must
buffer, and the buffer must be **bounded**:

* cap per stream (recommend **1 MiB**), 
* on overflow: `RST_STREAM(ENHANCE_YOUR_CALM)` for that stream and close the sink
  (never grow unbounded — a slow/stuck client must not OOM the server),
* log once per stream with the stream id so the cause is diagnosable.

### D5 — Webview flip: separate PR, behind a flag (recommended)

Land streaming + static first (they are independently testable with curl/nginx
tooling). The webview switch needs a per-backend cert-accept hook — WebView2
`ServerCertificateErrorDetected`, WKWebView `didReceiveAuthenticationChallenge`,
WebKitGTK `load-failed-with-tls-errors` — and **that is the one piece I have not
proven on any backend**. Recommend a short spike first (see T14) and the flip behind
`--web-https` so it is revertable in one line.

---

## 1. Constraints that shape the work

1. **The h1 SSE wire must stay byte-identical.** `sse_chunked_test.zig` asserts exact
   chunk bytes (`15\r\nevent: ping\ndata: 1\n\n\r\n`) and source-greps
   `http_server.zig` for `Transfer-Encoding: chunked` / `X-Accel-Buffering: no` /
   `Connection: close` (path pinned at `sse_chunked_test.zig:224`). Do not move those
   literals out of `http_server.zig`.
2. **One SSE stream per connection is not the model** — the app opens ONE global
   SSE, but the protocol must key sinks by `(connection, stream_id)`; never by fd
   again.
3. **h2 has no chunked encoding**: a body ends with an empty DATA frame carrying
   `END_STREAM`.
4. **The SSE route must not block the connection task.** Today the `.sse` arm holds
   the connection forever. On h2 the handler must *register* the sink and return, so
   the connection keeps reading (WINDOW_UPDATE, RST_STREAM, other streams).
5. **Cancellation:** a client `RST_STREAM` or `GOAWAY` must remove the sink and stop
   heartbeats for that stream (the h1 equivalent is EOF on the fd, which h2 does not
   have).
6. Windows must keep compiling and must not regress its (sleep-based) SSE loop.

## 2. File map

| File | Action | Responsibility |
|---|---|---|
| `src/modules/custom_http_server/src/http2/connection.zig` | EDIT | `beginStream`, `queueData`, `endStream`, `pending()` wake flag, bounded queue (D4), thread-safe queueing |
| `src/modules/custom_http_server/src/http2/server.zig` | EDIT | poll-based read loop + notify pipe (D2); `.sse` on h2 registers a sink instead of 501; static-over-h2 via `static_h2_handler` |
| `src/modules/custom_http_server/src/http2/tls.zig` | EDIT | `Conn.pending()` (D2c) |
| `src/modules/custom_http_server/src/sse_manager.zig` | EDIT | `SseSink` (D1): `writeEvent`, `endStream`; registry keyed by id with an optional h1 fd; heartbeat/broadcast/sweep go through the sink |
| `src/modules/custom_http_server/src/sse_sink.zig` | NEW | `SseSink` vtable + `H1Sink` (chunked, over a `Stream`) + `H2Sink` (DATA via `connection.queueData`) |
| `src/modules/custom_http_server/src/http_server.zig` | EDIT | h1 SSE arm passes an `H1Sink`; TLS gate for SSE becomes "h1 sink over TLS" (or stays 501 — see T8); `static_h2_handler` field + `setStaticH2Handler` |
| `src/main.zig` | EDIT | implement `staticH2Handler` (D3); `--web-https` flag (D5) |
| `src/apps/desktop_app/*` | EDIT | cert-accept hook per backend (D5/T14) |
| `tests/functional/http2_streaming_test.py` | NEW | SSE over h2 + SSE over h1+TLS + static over h2 (curl-driven) |
| `docs/http2-tls.md`, `docs/http2.md` | EDIT | flip the "known gap" sections to "landed" + verification |

## 3. Tasks (TDD, one commit each)

### Phase A — sink refactor (no behaviour change)

* **T1** `sse_sink.zig`: vtable + `H1Sink` that reproduces `writeChunkedFrame`/
  `sendAll` **exactly**. Tests: byte-for-byte equality with the current chunked
  framing (reuse the vectors already in `sse_chunked_test.zig`), empty event →
  `0\r\n\r\n`, `writeEvent` over a 16 KiB payload.
* **T2** `sse_manager.zig`: route the 6 write sites (`sendEvent:143`,
  `sendToClient:771`, `sendChunked:870`, `sendTerminatingChunk:881`,
  `gracefulShutdown:422`, `removeClient:287`/`removeClientByFd:305`/`sweepStaleClients:673`)
  through the sink; keep the fd only for the h1 poll/in/EOF path. **All existing SSE
  tests must pass unchanged** — that is the gate for this task.
* **T3** `http_server.zig`: the h1 SSE arm builds an `H1Sink` over the connection's
  `Stream` (so h1+TLS SSE works). Functional: `curl -N http://…/api/events` still
  streams; `curl -N -k https://…/api/events` now streams too (h1+TLS no longer 501).

### Phase B — h2 streaming

* **T4** `connection.zig`: `beginStream(stream_id, status, headers)` (HEADERS,
  `END_HEADERS`, no `END_STREAM`) + `queueData(stream_id, bytes, end_stream)` +
  `endStream(stream_id)`; reuse the existing `pending_bodies`/`flush()` machinery so
  window handling is shared. Tests: HEADERS then DATA then `END_STREAM`; a 40 KiB
  event splits at `MAX_FRAME_SIZE`; a 5-byte window sends 5 bytes then resumes after
  `WINDOW_UPDATE` (mirror the existing response test).
* **T5** bounded queue + overflow (D4): a stream whose window is exhausted and whose
  pending bytes exceed the cap is reset with `ENHANCE_YOUR_CALM`; the connection
  stays alive. Test with a client SETTINGS window of 0.
* **T6** thread-safe queueing: `queueData` behind a mutex + an atomic `pending`
  flag (SseManager writes from its own threads). Test: two threads queue to two
  streams concurrently and the frames stay well-formed.
* **T7** `H2Sink` in `sse_sink.zig` + `Conn.pending()` (D2c). Unit test with an
  in-memory connection (no socket): events become DATA frames; `endStream` sets
  `END_STREAM`; `conn.isClosed()` short-circuits writes.
* **T8** `http2/server.zig`: poll-based read loop + notify pipe (D2/D2b) and the
  `.sse` arm registers the sink instead of answering 501. Cancel on `RST_STREAM`/
  `GOAWAY` (T-specific: assert the sink is removed and heartbeats stop).
* **T9** Functional `tests/functional/http2_streaming_test.py`:
  `curl --http2 -N -k https://…/api/events?channels=workers` receives `connected`
  then a live event (trigger one via the API); assert the transfer stays open and no
  `Transfer-Encoding` header is present; a second stream on the SAME connection
  still gets responses (multiplexing with a parked SSE).

### Phase C — static over h2

* **T10** `http_server.zig`: `static_h2_handler` field + setter (D3) and the h2
  dispatcher calling it on a route miss (404 only when it is absent or misses).
* **T11** `src/main.zig`: implement `staticH2Handler` reusing the existing
  resolution (`writeStaticFileResponse` logic split into "resolve + read" and "emit
  h1"). Static-contract test that both handlers share the resolution path.
* **T12** Functional: over TLS+h2, `/app.css` and `/index.html` → 200 with correct
  `content-type`; a missing asset → 404; `--static-dir` absent → the plain 404.

### Phase D — flip the UI (D5, separate PR unless the reviewer says otherwise)

* **T13** Spike (timeboxed): prove the cert-accept hook on **one** backend first
  (WebKitGTK is the easiest to test headless on Linux) with a self-signed cert;
  write down exactly which callback/flag each backend needs.
* **T14** Implement the hooks for WebView2 + WKWebView + WebKitGTK behind
  `--web-https`, default **off**.
* **T15** Docs: "serving the UI over https" (cert location, trust story, the
  `--web-https` flag, and how to verify a tab shows `h2` in DevTools).

## 4. Verification per phase

| Phase | Gate |
|---|---|
| A | all existing SSE suites byte-identical (`sse_chunked_test.zig`, `sse_manager_test.zig`, `sse_keepalive_test.zig`, functional `sse_endtoend_test.py`) + new sink tests |
| B | module gate; `curl --http2 -N` streams over TLS; multiplexing test with a parked SSE stream; overflow test resets only that stream |
| C | `curl --http2` gets `/app.css` and `/index.html` over TLS with correct types; the webview's asset list fetches cleanly |
| D | the webview loads over `https://127.0.0.1` with live updates; `--web-https` off restores today's behaviour exactly |
| every | root gate `zig build test -Dno-webapp-rebuild` (0 failures) + the full `tests/functional/` suite |

## 5. Risks

| Risk | Mitigation |
|---|---|
| **h1 SSE bytes drift** during the sink refactor | T1 pins the framing against the existing vectors; `sse_chunked_test.zig`'s source-greps stay valid because the header literals do not move. |
| **Connection task blocked by a parked SSE** (the reason SSE was deferred) | T8's design: the handler registers and returns; the loop stays responsive and the notify pipe drives writes. The multiplexing test is the guard. |
| **Threading**: SseManager threads vs the connection task | T6 mutex + atomic pending flag; sink writes are idempotent no-ops once the connection/sink is closed. |
| **A slow client OOMs the server** | D4 bounded queue + `RST_STREAM(ENHANCE_YOUR_CALM)` (T5). |
| **poll + TLS buffered data stall** (D2c) | `Conn.pending()` drained before every poll; a test asserts an event delivered while another record is buffered still arrives. |
| **Windows has no `poll`** | D2b: timeout-based loop on Windows, same as the SSE manager's existing fork; functional coverage lives on Linux/macOS CI. |
| **Static h2 handler diverges from h1** | T11 shares the resolution function; T12 asserts both paths serve the same bytes/status for the same request. |
| **Cert-trust hooks are unproven per backend** | T13 spike first, one backend at a time, flag default off. |

## 6. Explicitly out of scope

WebSocket over h2 (RFC 8441 extended CONNECT) — the app registers no ws routes, and
WS over TLS/h2 stays 501 with a documented message. Server push, priorities, and
per-stream handler concurrency (handlers still run inline per connection) are
unchanged.
