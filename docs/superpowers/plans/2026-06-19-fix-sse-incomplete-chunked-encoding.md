# Plan: Fix `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` on SSE streams behind Vite dev proxy

**Date:** 2026-06-19
**Status:** Proposed
**Severity:** Medium — SSE streams work functionally, but every disconnect (refresh, tab close, navigation, backend restart) shows a red error in DevTools and the SseClient terminates after one attempt without retrying.
**Scope:** 1 backend module, 1 backend file (HTTP server), 4 SSE handlers, 1 Vite config, 1 frontend helper, regression tests

---

## Symptom (user report)

Screenshot of Chrome DevTools' Network panel shows three red rows
(plus one duplicate):

```
GET http://localhost:5173/api/sessions/stream     net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)
GET http://localhost:5173/api/sessions/stream     net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)
GET http://localhost:5173/api/workers/stream      net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)
```

The `200 (OK)` part is misleading: the *initial* HTTP response was
200 (handshake worked, the `event: connected` named event was
delivered, the frontend transitioned to `'open'`), but at some point
the chunked transfer encoding was terminated prematurely, so the
browser reported an incomplete chunked body.

The streams appear functional (events arrive, the badge shows
"Live", LLM tokens stream), but every page refresh and every backend
restart leaves a red error in DevTools, and the
`SseStatusBadge` ends up stuck on "Reconnecting…" or "Connection
lost" until the user reloads manually.

The `localhost:5173` URL confirms the traffic is going through the
**Vite dev proxy** (`vite.config.ts`), which forwards `/api/*` to the
Zig backend on `localhost:8081`.

---

## Root cause (full trace)

### Three problems stacked on top of each other

#### Problem 1 — Server side: SSE responses have neither `Content-Length` nor `Transfer-Encoding: chunked`

`src/modules/custom_http_server/src/http_server.zig:214` writes the SSE
response headers:

```zig
const headers = "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/event-stream\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "Connection: keep-alive\r\n" ++
    "Access-Control-Allow-Origin: *\r\n" ++
    "\r\n";
```

**No `Content-Length`. No `Transfer-Encoding: chunked`.** Per
[RFC 9112 §6](https://www.rfc-editor.org/rfc/rfc9112#section-6), a
response without either header is *implicitly framed by
connection-close*: the body extends until the server closes the
socket. For a long-lived SSE stream the connection is never closed,
so downstream intermediaries can't tell where one "message" ends
and another begins.

The Zig `SseManager` (`src/modules/custom_http_server/src/sse_manager.zig:378-388`)
sends events with raw byte writes:

```zig
pub fn sendToClient(self: *SseManager, id: [16]u8, data: []const u8) !void {
    const client = self.clients.get(id) orelse return error.ClientNotFound;
    const n = socket.write(client.?.fd, data.ptr, data.len);  // ← raw write(2)
    if (n < 0) {
        self.removeClient(id);
        return error.ClientDisconnected;
    }
}
```

Each event is one unframed raw byte sequence.

#### Problem 2 — Proxy side: Vite config has a non-functional workaround for buffering

`src/apps/desktop/vite.config.ts:24-39`:

```ts
proxy: {
  '/api': {
    target: 'http://localhost:8081',
    changeOrigin: true,
    configure: (proxy) => {
      proxy.on('proxyRes', (proxyRes) => {
        if (proxyRes.headers['transfer-encoding'] === 'chunked') {
          proxyRes.headers['x-no-proxy-buffering'] = 'true';   // ← no-op!
        }
      });
    },
    timeout: 300000,
  },
},
```

`x-no-proxy-buffering` is a **CloudFront-specific header** for the
CloudFront CDN. It has no meaning for `http-proxy` (the underlying
proxy library Vite uses). The `configure` callback sets a response
header that no proxy in the chain will act on.

The actual mechanism to disable `http-proxy` response buffering is
the `selfHandleResponse: true` option, combined with manually
piping the upstream response stream to the downstream response.
None of that is configured today.

Net effect: by default `http-proxy` will buffer the *entire
upstream response* until the upstream connection closes. For SSE
that never happens during normal use, so the browser may not
receive events in real-time, and when the buffer finally flushes
(on disconnect, proxy timeout, or backend restart) the chunked
framing is incomplete.

#### Problem 3 — Server side: raw `write(2)` without `MSG_NOSIGNAL` (latent)

`sse_manager.zig:67-71` and `:367-371` use raw `socket.write`:

```zig
const n = socket.write(self.fd, event.ptr, event.len);
```

`write(2)` on a TCP socket whose peer has closed raises `SIGPIPE`,
which (if unhandled) terminates the Zig process with exit code 141.
The `n < 0` check on the next line only fires after SIGPIPE
delivery, by which point the process is already dead.

In normal operation this is masked by Vite's buffering (the proxy
absorbs the `EPIPE` from its own side), but if any code path calls
`sendToClient` against a known-dead client (e.g. after the client
has been removed but a callback still holds the id), the whole
`nalar` process dies.

The right primitive is `send(2)` with `MSG_NOSIGNAL`. The Zig
0.16 stdlib exposes `std.os.linux.send` (raw syscall) which
accepts flags.

### Why `200 (OK)` even though the encoding is broken

The browser fires `ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` when:

1. The HTTP status line (with `HTTP/1.1 200 OK`) and the response
   headers arrived in full — that part worked, so the status code
   the browser remembers is 200.
2. The body declared chunked transfer encoding — but it never
   finished. The browser is using HTTP/1.1 with `Transfer-Encoding:
   chunked` because **Vite's http-proxy implicitly adds that header
   to the downstream response** when the upstream response has no
   `Content-Length`. It does this so it can stream chunks as they
   arrive from upstream without buffering the entire response.
3. When Vite's upstream socket to the Zig backend closes (or Vite's
   buffer flushes after `proxy timeout` expires, or the user
   navigates), Vite either fails to send the terminating
   `0\r\n\r\n` chunk, or sends an unexpected mid-stream termination.
   The browser sees an incomplete chunked encoding.

The user sees the error in DevTools but the stream worked in
practice because:

- The `event: connected` handshake was already delivered as the
  first chunk.
- Real-time events were delivered as subsequent chunks.
- The error only fires on disconnect / timeout, not during normal
  operation.

---

## Proposed fix

Three layers, applied in order. Each layer is independently
testable; later layers do not depend on earlier ones, but the
overall behavior is correct only when all three are in place.

### Layer 1 — Server side: proper HTTP/1.1 chunked transfer encoding

Add `Transfer-Encoding: chunked` to the SSE response headers in
`http_server.zig`, and wrap every event write in the proper chunked
encoding format:

```
<length in hex>\r\n
<data>\r\n
```

…terminated by a final `0\r\n\r\n` chunk when the connection is
closing (POLL.HUP detected, graceful shutdown, etc.).

This is the standard way to do SSE on HTTP/1.1 and it is what
browsers, Vite, nginx, AWS ALB, and every other intermediary
expects. Once the upstream declares chunked encoding, Vite
**stops trying to re-frame the response** and forwards chunks
transparently.

#### Files to change

| File | Change |
|------|--------|
| `src/modules/custom_http_server/src/http_server.zig` | Add `Transfer-Encoding: chunked` to the SSE response headers (line 214). Add a helper to wrap writes in chunked encoding. Add `MSG_NOSIGNAL` to all writes to client sockets (via `send(2)`). Send the terminating `0\r\n\r\n` chunk on graceful shutdown and on per-client disconnect. |
| `src/modules/custom_http_server/src/sse_manager.zig` | Refactor `sendToClient`, `sendEvent`, `sendHeartbeat`, `broadcast`, and `broadcastTyped` to write through the new chunked-encoding helper. Replace raw `socket.write` with `std.os.linux.send` (with `MSG_NOSIGNAL` flag) on Linux; keep `write` on macOS/Windows (or use platform-specific code). |
| `src/modules/custom_http_server/src/sse_manager_test.zig` | Add regression tests for chunked-encoded writes. |

### Layer 2 — Proxy side: actually disable Vite response buffering

Replace the non-functional `x-no-proxy-buffering` workaround with
the real mechanism: `selfHandleResponse: true` plus manual piping.

The `configure` callback receives a `proxy` object whose
`selfHandleResponse` flag tells `http-proxy` "don't write to the
downstream response, I will do it myself." We then stream the
upstream response chunks directly to the downstream response with
no buffering.

#### Files to change

| File | Change |
|------|--------|
| `src/apps/desktop/vite.config.ts` | Replace the `configure` block with a `selfHandleResponse: true` handler that pipes the upstream response stream to the downstream response, with the `Cache-Control: no-store` and `X-Accel-Buffering: no` headers set on the downstream response (the latter is the de-facto standard signal for "disable buffering" across nginx, AWS ALB, and Cloudflare). |

### Layer 3 — Client side: make `ERR_INCOMPLETE_CHUNKED_ENCODING` trigger a reconnect

Today, `SseClient.handleError` (`src/apps/desktop/src/helpers/sseClient.ts:567-609`)
treats the *first* error as fatal (`!hasBeenOpen → 'failed'`).
That's correct for genuine 4xx/5xx errors, but a transport-level
`ERR_INCOMPLETE_CHUNKED_ENCODING` is recoverable if the stream was
ever live — exactly the case we are seeing. The current logic
handles this correctly via `hasBeenOpen`:

```ts
if (!hasBeenOpen) {
  emitState('failed', { ... })  // fatal
  return
}
// ... otherwise scheduleRetry(...)
```

So the client logic is already correct. No code changes needed in
Layer 3; the verification step is to confirm that, after Layer 1 +
Layer 2 land, a refresh that triggers `ERR_INCOMPLETE_CHUNKED_ENCODING`
results in `'reconnecting'` (then `'open'`), not `'failed'`.

---

## Files to change (summary)

| Layer | File | Lines | Risk |
|-------|------|-------|------|
| 1 | `src/modules/custom_http_server/src/http_server.zig` | ~214 | Low — additive header, helper function |
| 1 | `src/modules/custom_http_server/src/sse_manager.zig` | 5 call sites + 1 helper | Medium — touches the hot write path |
| 1 | `src/modules/custom_http_server/src/sse_manager_test.zig` | new tests | Low |
| 1 | `src/modules/custom_http_server/src/test_session_lifecycle.zig` | may need adjustment | Low |
| 2 | `src/apps/desktop/vite.config.ts` | ~24-39 | Low — only affects dev mode |

No production-binary build target changes. No new dependencies. No
database migrations. No frontend type changes.

---

## Task breakdown

The work is split into 5 tasks, each ending in a green test +
commit.

### Task 1: Add chunked-encoding helper to `sse_manager.zig`

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_manager.zig`
- Test: `src/modules/custom_http_server/src/sse_manager_test.zig`

**Why this is its own task:** the chunked-encoding helper is a
new public API (`SseManager.sendChunked`, `SseClient.writeChunk`)
that all later tasks depend on. Build it with a focused
test, land it on its own, then refactor the call sites in Task 2.

- [ ] **Step 1.1:** Write a failing test in
  `sse_manager_test.zig` that calls `SseManager.sendChunked(client_id, "event: ping\ndata: 1\n\n")`
  on a registered client backed by a `socketpair`, reads the bytes
  on the other end with `read()`, and asserts the bytes equal
  `"1b\r\nevent: ping\ndata: 1\n\n\r\n"` (where `1b` = `0x1b` =
  hex of 27, the length of the data).

  Use the existing `createSocketPair()` helper from the same file
  (`sse_manager_test.zig:9-37`).

- [ ] **Step 1.2:** Run the test to confirm it fails. Expected:
  compile error `no member named 'sendChunked' in struct 'SseManager'`
  OR runtime error (depends on which order tests run in).

  Run: `timeout 120 zig build test --summary all 2>&1 | tail -n 30`

- [ ] **Step 1.3:** Add `sendChunked` and `sendTerminatingChunk`
  to `SseManager` in `sse_manager.zig`.

  ```zig
  /// Send `data` as one HTTP/1.1 chunked-transfer-encoding frame
  /// on the wire: `<hex length>\r\n<data>\r\n`. Returns
  /// `error.ClientDisconnected` if the peer hung up (peer socket
  /// closed) or `error.WriteFailed` if the write itself failed.
  ///
  /// Allocates a small stack-buffer for the length header (16 bytes
  /// is enough for any 64-bit length). Does NOT use the arena —
  /// the header is a stack scratch.
  pub fn sendChunked(self: *SseManager, id: [16]u8, data: []const u8) !void {
      const client = self.clients.get(id) orelse return error.ClientNotFound;

      var len_buf: [16]u8 = undefined;
      const len_str = std.fmt.bufPrint(&len_buf, "{x}\r\n", .{data.len}) catch
          return error.WriteFailed;
      const trailer = "\r\n";

      // Single sendmsg() would be ideal, but std.os.linux.send
      // takes one buffer + flags. Use a 3x send loop.
      var send_flags: u32 = std.os.linux.MSG_NOSIGNAL;
      if (builtin.os.tag != .linux) send_flags = 0;

      const n1 = sendAll(client.fd, len_str, send_flags);
      if (n1 < len_str.len) {
          self.removeClient(id);
          return error.ClientDisconnected;
      }
      const n2 = sendAll(client.fd, data, send_flags);
      if (n2 < data.len) {
          self.removeClient(id);
          return error.ClientDisconnected;
      }
      const n3 = sendAll(client.fd, trailer, send_flags);
      if (n3 < trailer.len) {
          self.removeClient(id);
          return error.ClientDisconnected;
      }
  }

  /// Send the chunked-encoding terminator: `0\r\n\r\n`. Call this
  /// once on every SSE connection just before closing the socket,
  /// so that intermediaries (Vite, browser) can finalize their
  /// chunked decoding state cleanly. Failure is non-fatal — the
  /// socket close itself signals end-of-stream.
  pub fn sendTerminatingChunk(self: *SseManager, id: [16]u8) void {
      const client = self.clients.get(id) orelse return;
      var send_flags: u32 = std.os.linux.MSG_NOSIGNAL;
      if (builtin.os.tag != .linux) send_flags = 0;
      _ = sendAll(client.fd, "0\r\n\r\n", send_flags);
  }

  /// Write all of `data` to `fd`, looping on short writes. Returns
  /// the number of bytes actually written, or -1 on error.
  fn sendAll(fd: i32, data: []const u8, flags: u32) isize {
      if (builtin.os.tag == .linux) {
          var sent: usize = 0;
          while (sent < data.len) {
              const rc = std.os.linux.send(fd, data[sent..].ptr, data.len - sent, flags);
              if (rc > std.math.maxInt(i32)) return -1; // errno
              const n: isize = @intCast(rc);
              if (n < 0) return -1;
              if (n == 0) return -1;
              sent += @as(usize, @intCast(n));
          }
          return @intCast(sent);
      } else {
          // macOS / Windows: use posix.system.write (no MSG_NOSIGNAL)
          var sent: usize = 0;
          while (sent < data.len) {
              const rc = std.posix.system.write(fd, data[sent..].ptr, data.len - sent);
              if (rc < 0) return -1;
              sent += @as(usize, @intCast(rc));
          }
          return @intCast(sent);
      }
  }
  ```

  Add the new imports at the top of `sse_manager.zig`:
  ```zig
  const builtin = @import("builtin");
  ```
  (already present, verify).

  Add `pub` to the existing `SseManager.sendToClient` if needed,
  or have callers go through `sendChunked` instead.

- [ ] **Step 1.4:** Run the test from Step 1.1. Expected: PASS.

  Run: `timeout 120 zig build test --summary all 2>&1 | tail -n 30`

- [ ] **Step 1.5:** Commit.

  ```bash
  git add src/modules/custom_http_server/src/sse_manager.zig \
          src/modules/custom_http_server/src/sse_manager_test.zig
  git commit -m "feat(http_server): add SseManager.sendChunked for HTTP/1.1 chunked SSE"
  ```

### Task 2: Refactor existing call sites to use `sendChunked`

**Files:**
- Modify: `src/modules/custom_http_server/src/sse_manager.zig`
  (5 sites: `sendToClient` at line 378, `broadcast` at line 390,
  `broadcastTyped` at line 410, `sendHeartbeat` at line 346,
  `gracefulShutdown` at line 214, `SseClient.sendEvent` at line 63)

- [ ] **Step 2.1:** Refactor `SseClient.sendEvent` to write
  through `sendChunked`. This is the per-client hot path.

  Change `sse_manager.zig:63-72` from:
  ```zig
  pub fn sendEvent(self: *SseClient, event: []const u8) !void {
      self.lock.lock();
      defer self.lock.unlock();
      if (!self.alive) return error.ClientDisconnected;
      const n = socket.write(self.fd, event.ptr, event.len);
      if (n < 0) {
          self.alive = false;
          return error.ClientDisconnected;
      }
  }
  ```
  to:
  ```zig
  pub fn sendEvent(self: *SseClient, event: []const u8) !void {
      self.lock.lock();
      defer self.lock.unlock();
      if (!self.alive) return error.ClientDisconnected;
      const len_buf = ...; // same as in sendChunked
      // Inline the 3-write loop here (or call a static helper)
      ...
  }
  ```
  Or, more cleanly, expose a free function
  `writeChunkedFrame(fd: i32, data: []const u8) !void` that both
  `sendChunked` (which looks up the client id) and `sendEvent`
  (which already has the client) can call.

- [ ] **Step 2.2:** Refactor `sendToClient` to call
  `writeChunkedFrame` instead of raw `socket.write`. Same for
  `broadcast` and `broadcastTyped`. Same for `sendHeartbeat`
  (the `data: ping\n\n` constant becomes a chunked frame).

- [ ] **Step 2.3:** Refactor `gracefulShutdown` to send the
  terminating `0\r\n\r\n` chunk to every client before closing
  the socket. Change `sse_manager.zig:214-237` to call
  `self.sendTerminatingChunk(id)` before the `forceDestroy()`
  call.

- [ ] **Step 2.4:** Refactor `removeClient` and
  `removeClientByFd` to send the terminating chunk before
  closing the fd. This handles the POLL.HUP disconnect case:
  the peer is already gone, so the write will fail silently
  (which is fine — we don't care if the terminator reaches a
  dead peer).

- [ ] **Step 2.5:** Run the existing SSE manager tests. They
  should still pass because the wire-level behavior is
  observably the same (socketpair read sees the same bytes, just
  with a chunked encoding wrapper around them).

  Run: `timeout 120 zig build test --summary all 2>&1 | tail -n 30`
  Expected: 100% of existing `sse_manager_test.zig` tests pass.

  **If a test fails because it was asserting on raw bytes** (e.g.
  expecting exactly `"data: ping\n\n"` on the wire), update the
  assertion to expect the chunked-encoded form
  (`"8\r\ndata: ping\n\n\r\n"`). Document the change in the test
  file's header comment.

- [ ] **Step 2.6:** Add one more regression test:
  `sendChunked sends the terminating chunk on removeClient`.
  Register a client, send one event, call `removeClient`, then
  read the socket on the other side and assert the bytes are
  exactly `"<hex len>\r\n<event>\r\n0\r\n\r\n"`.

- [ ] **Step 2.7:** Commit.

  ```bash
  git add src/modules/custom_http_server/src/sse_manager.zig \
          src/modules/custom_http_server/src/sse_manager_test.zig
  git commit -m "refactor(http_server): route all SSE writes through chunked encoding"
  ```

### Task 3: Add `Transfer-Encoding: chunked` to the SSE response headers

**Files:**
- Modify: `src/modules/custom_http_server/src/http_server.zig` line 214

- [ ] **Step 3.1:** Change the SSE response headers constant at
  `http_server.zig:214` from:

  ```zig
  const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
  ```

  to:

  ```zig
  const headers = "HTTP/1.1 200 OK\r\n" ++
      "Content-Type: text/event-stream\r\n" ++
      "Cache-Control: no-cache\r\n" ++
      "Connection: keep-alive\r\n" ++
      // Required by HTTP/1.1: a response with neither Content-Length
      // nor Transfer-Encoding is implicitly framed by connection-close.
      // For SSE we never close the connection voluntarily, so we MUST
      // declare chunked encoding. Otherwise Vite / proxies / browsers
      // will misinterpret the response and surface
      // ERR_INCOMPLETE_CHUNKED_ENCODING on disconnect.
      "Transfer-Encoding: chunked\r\n" ++
      // Tell intermediaries (Vite, nginx, Cloudflare, ALB) not to
      // buffer. X-Accel-Buffering is the de-facto convention.
      "X-Accel-Buffering: no\r\n" ++
      "Access-Control-Allow-Origin: *\r\n" ++
      "\r\n";
  ```

- [ ] **Step 3.2:** Add a regression test that captures the
  exact headers string and asserts it contains
  `Transfer-Encoding: chunked`. The test can live in
  `http_server_test.zig` as a static check on the source file
  (mirroring `sse_handshake_test.zig` for the `event: connected`
  pattern):

  ```zig
  test "HTTP server: SSE response declares Transfer-Encoding: chunked" {
      const source = try std.Io.Dir.cwd().readFileAlloc(
          std.testing.io,
          "src/modules/custom_http_server/src/http_server.zig",
          std.testing.allocator,
          .limited(64 * 1024),
      );
      defer std.testing.allocator.free(source);

      if (std.mem.indexOf(u8, source, "Transfer-Encoding: chunked") == null) {
          std.debug.print("\n!! http_server.zig missing Transfer-Encoding: chunked !!\n", .{});
          return error.TransferEncodingChunkedMissing;
      }
  }
  ```

  Register this in
  `src/modules/custom_http_server/src/test_runner.zig`.

- [ ] **Step 3.3:** Run the test. Expected: PASS.

  Run: `timeout 120 zig build test --summary all 2>&1 | tail -n 30`

- [ ] **Step 3.4:** Commit.

  ```bash
  git add src/modules/custom_http_server/src/http_server.zig \
          src/modules/custom_http_server/src/http_server_test.zig \
          src/modules/custom_http_server/src/test_runner.zig
  git commit -m "fix(http_server): declare Transfer-Encoding: chunked on SSE responses"
  ```

### Task 4: Fix the Vite proxy to actually disable buffering

**Files:**
- Modify: `src/apps/desktop/vite.config.ts`

- [ ] **Step 4.1:** Replace the existing `proxy` block in
  `vite.config.ts:24-39` with a `selfHandleResponse: true`
  implementation:

  ```ts
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8081',
        changeOrigin: true,
        // We take over writing the downstream response ourselves so
        // http-proxy does not buffer the upstream SSE body. The
        // previous version set `x-no-proxy-buffering` (a CloudFront-
        // specific header) inside the `configure` callback, which
        // http-proxy ignores — that's why SSE events arrived in
        // bursts instead of real-time, and the browser DevTools
        // showed ERR_INCOMPLETE_CHUNKED_ENCODING on disconnect.
        selfHandleResponse: true,
        configure: (proxy) => {
          proxy.on('proxyReq', (proxyReq, req) => {
            // Forward the request as-is. Nothing to do here; the
            // important work is in `proxyRes` below.
          });
          proxy.on('proxyRes', (proxyRes, req, res) => {
            // Mirror upstream status / headers that matter for SSE.
            // Do NOT touch Transfer-Encoding: the upstream (Zig) now
            // sends chunked-encoded frames (see Task 3) and we want
            // to forward those bytes verbatim.
            res.statusCode = proxyRes.statusCode ?? 200;
            for (const [key, value] of Object.entries(proxyRes.headers)) {
              // Skip hop-by-hop headers (per RFC 9110 §7.6.1) — these
              // are managed by the HTTP stack, not forwarded.
              if (
                key.toLowerCase() === 'transfer-encoding' ||
                key.toLowerCase() === 'connection' ||
                key.toLowerCase() === 'keep-alive' ||
                key.toLowerCase() === 'upgrade'
              ) {
                continue;
              }
              res.setHeader(key, value as string | string[]);
            }
            // Set the de-facto "don't buffer me" header for any
            // downstream intermediary that respects it (nginx, ALB,
            // Cloudflare). This is the standard SSE hardening header.
            res.setHeader('X-Accel-Buffering', 'no');

            // Pipe the upstream body to the downstream response
            // without buffering. Each 'data' event from proxyRes is
            // one chunked-encoded frame from the Zig backend; we
            // forward it as-is.
            proxyRes.on('data', (chunk: Buffer) => {
              // res.write returns false if the downstream buffer is
              // full; we do NOT pause proxyRes because http-proxy's
              // backpressure handling for SSE is unreliable. The
              // downstream socket will apply TCP backpressure itself.
              res.write(chunk);
            });
            proxyRes.on('end', () => {
              res.end();
            });
            proxyRes.on('error', (err: Error) => {
              // Upstream died (e.g. backend restart). End the
              // downstream response so the browser sees a clean
              // chunked-encoding terminator instead of
              // ERR_INCOMPLETE_CHUNKED_ENCODING.
              if (!res.writableEnded) {
                res.end();
              }
            });
          });
        },
        timeout: 300_000, // 5 minutes; matches the previous value
      },
    },
  },
  ```

  Add the `Buffer` import at the top of the file:
  ```ts
  import type { Buffer } from 'node:buffer'
  ```

- [ ] **Step 4.2:** Verify the TypeScript types compile.

  Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 30`
  Expected: no type errors, build succeeds.

  **Note:** `bun run build` runs `vue-tsc --build`, which is the
  authoritative type-check (NOT `vitest run`). See
  `.nalar/memories/desktop-typescript-bun-build-as-typecheck.md`.

- [ ] **Step 4.3:** Manual smoke test against the running dev
  server.

  1. Start the Zig backend on port 8081 (existing process).
  2. `cd src/apps/desktop && bun run dev` (starts Vite on 5173).
  3. Open Chrome → DevTools → Network panel.
  4. Open `http://localhost:5173/` (the desktop app).
  5. Confirm SSE connections show "open" (not "pending") within
     milliseconds.
  6. Trigger a backend event (e.g. create a new chat session).
     Confirm the event arrives in the browser UI within ~100 ms
     (NOT after a multi-second buffering delay).
  7. Refresh the page. Confirm the SSE connection in DevTools
     shows "canceled" (NOT a red
     `ERR_INCOMPLETE_CHUNKED_ENCODING`).

- [ ] **Step 4.4:** Add a vitest test that exercises the Vite
  config in isolation. The test imports `vite.config.ts`, inspects
  the exported `default` object, and asserts:
  - `server.proxy['/api'].selfHandleResponse === true`
  - `server.proxy['/api'].configure` is a function
  - the configure function does NOT contain the string
    `'x-no-proxy-buffering'` (regression guard against the
    no-op workaround sneaking back in)

  Filename: `src/apps/desktop/src/__tests__/viteConfig.spec.ts`
  (or similar). Register in
  `src/apps/desktop/vitest.config.ts` if needed.

- [ ] **Step 4.5:** Commit.

  ```bash
  git add src/apps/desktop/vite.config.ts \
          src/apps/desktop/src/__tests__/viteConfig.spec.ts
  git commit -m "fix(vite): disable SSE buffering via selfHandleResponse, drop x-no-proxy-buffering no-op"
  ```

### Task 5: End-to-end verification

**Files:** none modified — verification only.

- [ ] **Step 5.1:** Run the full Zig test suite. All tests must
  pass.

  Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 30`
  Expected: `test success`, count ≥ pre-existing baseline.

- [ ] **Step 5.2:** Run the full Vue/TS test suite. All tests
  must pass.

  Run:
  ```
  cd src/apps/desktop
  timeout 240 bun run build 2>&1 | tail -n 30
  timeout 240 bunx vitest run 2>&1 | tail -n 30
  ```
  Expected: build clean, vitest green.

- [ ] **Step 5.3:** Manual end-to-end test in a real browser.

  1. Start backend: `./zig-out/bin/nalar --port 8081 &`
  2. Start frontend: `cd src/apps/desktop && bun run dev`
  3. Open Chrome → `http://localhost:5173/`
  4. Open DevTools → Network panel
  5. Confirm the three SSE streams are listed:
     - `localhost:5173/api/sessions/stream` (status "open")
     - `localhost:5173/api/workers/stream` (status "open")
     - `localhost:5173/api/llm/stream/<sessionId>` (status "open")
     - `localhost:5173/api/llm/session/<sessionId>/queue_messages/stream` (status "open")
  6. Refresh the page (Cmd-R / F5). The SSE rows should
     transition to "canceled" or disappear — they should NOT
     show red `ERR_INCOMPLETE_CHUNKED_ENCODING` rows.
  7. Send a chat message and confirm LLM tokens stream in
     real-time (no multi-second buffering delay).
  8. Restart the backend (kill and relaunch). The frontend
     should auto-reconnect within 1-30 s (depending on backoff
     state) and resume streaming. NO red errors in DevTools.

- [ ] **Step 5.4:** Capture before/after screenshots. Save to
  `docs/before-after-sse-chunked-fix/` (gitignored).

- [ ] **Step 5.5:** Update the global memory file
  `~/.config/nalar/memories/` with a new entry titled
  "SSE responses must declare Transfer-Encoding: chunked,
  Vite proxy needs selfHandleResponse". This is a future
  engineer-facing note that prevents the same bug from
  recurring in new SSE handlers / new Vite configs.

---

## Verification (overall)

After all 5 tasks land:

1. `timeout 240 zig build test --summary all` → 100% pass.
2. `cd src/apps/desktop && timeout 240 bun run build` → 100%
   type-check pass, 100% test pass.
3. Manual browser test:
   - 4 SSE streams all show "open" within 100 ms.
   - No red `ERR_INCOMPLETE_CHUNKED_ENCODING` rows appear on
     refresh, navigation, or backend restart.
   - The `SseStatusBadge` stays on "Live" through backend
     restarts (auto-reconnects via the existing `SseClient`
     backoff).

## Pitfalls

### `send(2)` flags and platform differences

`MSG_NOSIGNAL` is a Linux-and-BSD-only flag. On Windows,
`WSASend` uses `MSG_NOSIGNAL` semantics by default (the
`SIGPIPE` equivalent doesn't exist on Windows). On macOS,
`MSG_NOSIGNAL` is defined as `0x4000` in `<sys/socket.h>`.

The plan's helper uses `std.os.linux.send` directly on Linux
(simplest) and falls back to `posix.system.write` on other
platforms. **Verify the `std.os.linux.send` import exists** in
the project's Zig 0.16 stdlib. If it doesn't, use
`posix.system.sendto` or fall back to a manual syscall.

### `socket.write` return type is platform-specific

`posix.system.write` returns a `usize` (success) or
`-errno`-encoded `usize` on Linux. The current code checks
`n < 0` which works because the failure encoding is always
a large `usize` value (it's a `c_int` errno in disguise, so
`-1` is also a valid "negative" indicator when interpreted as
`isize`). The new `sendAll` helper uses `> std.math.maxInt(i32)`
to detect the failure encoding per the project's
`zig-0.16-syscall-helpers.md` memory.

### The `sendEvent` lock pattern

`SseClient.sendEvent` takes a `self.lock` mutex around the
write. With chunked encoding, we now do 3 writes per call
(length header, data, trailer). The lock MUST cover all 3
writes atomically — otherwise a concurrent thread could
write another event between the length header and the data,
producing interleaved garbage on the wire.

### Vite proxy type signatures

`http-proxy`'s TypeScript types are notoriously loose.
The `proxyRes.on('data', ...)` callback signature has changed
across versions. Pin the project's `http-proxy` to a known
version in `package.json` before writing the test. If the
project's Vite 8.x bundles a specific `http-proxy` version,
discover it via `npm ls http-proxy` (run inside
`src/apps/desktop`).

### The heartbeat `data: ping\n\n` becomes chunked too

After Task 2, the heartbeat is sent as `7\r\ndata: ping\n\n\r\n`
(7 bytes of data, hex `7`). The frontend `SseClient.heartbeatData`
filter checks `raw === heartbeatData`, where `raw` is the
`MessageEvent.data` string. The browser parses the chunked
encoding and reconstructs the original bytes before dispatching
to the `message` event listener — so `raw` is still `'ping'`.
The filter still works. **Verify** with a test that sends a
heartbeat and reads `e.data` on the browser side.

### `http_server.zig` import cycle risk

Adding a new helper to `sse_manager.zig` and referencing it
from `http_server.zig` does not create an import cycle
(both files are in the same package and `sse_manager.zig`
already imports `http_parser.zig` types). Verify by running
`zig build install:linux:system` after Task 3 lands.

### The SseStatusBadge regression

After Layer 1 + Layer 2 land, the `SseStatusBadge` should
behave as before: transition to `'open'` on the
`event: connected` handshake, transition to `'reconnecting'`
on `onerror`, transition to `'failed'` only on first-attempt
fatal error. The `sse_handshake_test.zig` static check
should still pass.

---

## Out of scope (deferred)

- Adding `Last-Event-ID` support for SSE resumption (RFC
  8895). Not currently requested by the frontend.
- HTTP/2 server push for SSE. Not relevant — the project
  uses HTTP/1.1.
- Replacing `http-proxy` with a custom Node-side proxy. Out
  of scope for a Vite-only fix; would require rewriting
  the dev server entry point.
- Migrating from `EventSource` to a fetch-based streaming
  client (e.g. `fetch().then(r => r.body.getReader())`). Out
  of scope — `EventSource` has built-in auto-reconnect and is
  the right tool here.

---

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Chunked-encoding helper has a bug that mangles frames | Medium | High (breaks all SSE) | Layer 1 tasks have focused regression tests; manual smoke test in Task 5 |
| Vite proxy changes break non-SSE endpoints | Low | Medium | `selfHandleResponse` only applies to the `/api` proxy block; non-SSE endpoints still work |
| `MSG_NOSIGNAL` flag has wrong value on macOS | Low | Low | Helper has explicit platform branch; cross-compile not in scope |
| Frontend `SseClient.heartbeatData` filter breaks | Low | Low | Browser reassembles chunked encoding before dispatching; manual smoke test confirms |
| `SIGPIPE` regression from incomplete platform coverage | Low | High (kills nalar process) | Helper uses `send(2)` on Linux; tested in Task 1 |

---

## Estimated effort

| Task | Lines changed | Estimated time |
|------|--------------|----------------|
| 1. sendChunked helper | ~80 lines + 30 test | 1-2 hours |
| 2. Refactor call sites | ~50 lines + 30 test | 1-2 hours |
| 3. Add Transfer-Encoding header | ~10 lines + 20 test | 30 minutes |
| 4. Fix Vite proxy | ~60 lines + 30 test | 1 hour |
| 5. E2E verification | manual | 30 minutes |
| **Total** | ~340 lines | **~5-7 hours** |

---

## Reference: HTTP/1.1 chunked transfer encoding wire format

For any reviewer unfamiliar with the chunked encoding format:

```
HTTP/1.1 200 OK\r\n
Transfer-Encoding: chunked\r\n
Content-Type: text/event-stream\r\n
\r\n                  ← end of response headers
3c\r\n                ← chunk 1: 60 bytes (0x3c) follow
event: connected\ndata: {"connected": true}\n\n   ← chunk 1 data
\r\n                  ← chunk 1 terminator
1b\r\n                ← chunk 2: 27 bytes (0x1b) follow
event: foo\ndata: bar\n\n   ← chunk 2 data
\r\n                  ← chunk 2 terminator
0\r\n                 ← last chunk: 0 bytes
\r\n                  ← chunked encoding terminator
```

Each chunk is: `<hex length>\r\n<data>\r\n`. The terminating
chunk is `0\r\n\r\n`. After the terminating chunk, the server
closes the connection (or sends trailers, which we don't need
for SSE).

`\r\n` is **two bytes** (carriage return + newline), NOT one.
`\n` is **one byte**. The plan's `writeChunkedFrame` helper
uses the correct two-byte CRLF separators.