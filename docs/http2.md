# HTTP/2 (h2c) in `custom_http_server`

Status: **implemented, opt-in, off by default.** Enable with `--http2 h2c`.

The server (`src/modules/custom_http_server`) now speaks two wire protocols on the
same port:

| Client sends first | Codec | Notes |
|---|---|---|
| `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` (24-byte preface) | **HTTP/2 (h2c)** | prior-knowledge, cleartext |
| anything else | **HTTP/1.1** | byte-for-byte unchanged |

With the flag absent, the sniff block never runs and the HTTP/1.1 path is
identical to before this change.

## Why h2c and not "real" HTTP/2

Browsers only use HTTP/2 over **TLS with ALPN** (`h2`). This server has no TLS at
all, and adding it (certificates, trust, webview plumbing) is a separate project.
So this work targets **non-browser clients**: `curl --http2-prior-knowledge`,
nghttp2-based tooling, service-mesh sidecars (envoy/HAProxy h2c upstream),
agents, and other internal callers. Browsers keep using HTTP/1.1 and notice
nothing. TLS + ALPN is the follow-up that would unlock browser-side multiplexing.

## What is implemented

* **Frames** (RFC 9113): DATA, HEADERS, PRIORITY (parsed, ignored), RST_STREAM,
  SETTINGS (+ ACK), PING (+ ACK), GOAWAY, WINDOW_UPDATE, CONTINUATION.
  PUSH_PROMISE from a client → `GOAWAY(PROTOCOL_ERROR)` (clients cannot push).
  Unknown frame types are ignored, as the RFC requires.
* **HPACK** (RFC 7541): full decoder (static + dynamic table, integer/string
  primitives, Huffman) and a minimal-correct encoder (exact static matches use
  the indexed form; everything else is literal-without-indexing and never grows a
  dynamic table). The tables and the conformance vectors are **generated** — see
  `tools/gen_hpack_tables.py`.
* **Flow control**: connection and stream windows, coalesced WINDOW_UPDATE at
  half-window, SETTINGS_INITIAL_WINDOW_SIZE deltas applied to open streams.
* **Multiplexing**: several streams per connection, answered in any order.
* **Limits** (advertised in our SETTINGS): `MAX_CONCURRENT_STREAMS=128`,
  `INITIAL_WINDOW_SIZE=1 MiB`, `MAX_FRAME_SIZE=16384`, `ENABLE_PUSH=0`,
  `MAX_HEADER_LIST_SIZE=64 KiB`. Request bodies are additionally capped
  (`max_body_bytes`, default 16 MiB) with `RST_STREAM(ENHANCE_YOUR_CALM)`.

## Known gaps (deliberate, phase 1)

1. **SSE and WebSocket routes answer `501` over HTTP/2.** `SseManager` keys
   clients by file descriptor, polls that fd for EOF, closes it on removal and
   writes HTTP/1.1 chunk terminators — none of which maps onto one fd carrying N
   streams. Both routes remain fully available over HTTP/1.1, which is what the
   browser uses.
2. **No static files over HTTP/2.** The `--static-dir` handler writes raw
   HTTP/1.1 bytes to the socket, and the module cannot import
   `src/static_files.zig` (outside its package path). h2 requests for unknown
   routes get the normal 404. Converting the static handler to a codec-neutral
   writer is a self-contained follow-up.
3. **No TLS/ALPN**, so no browser h2 (see above).
4. **One task per connection, handlers run inline.** Streams are multiplexed on
   the wire, but handler execution is serialized per connection. This is
   deliberate: it removes the classic h2 deadlock where a writer waits for
   WINDOW_UPDATE while nobody is reading. Per-stream tasks are a later
   optimization.
5. **Stream priorities are ignored** (accepted and dropped, per RFC 9113 §5.3).

## Layering

```
src/connection_reader.zig      peek the first bytes; `sniff()` decides h2 vs h1
src/http2/constants.zig        frame types, flags, error codes, settings, limits
src/http2/frame.zig            9-byte header codec, padding, payload helpers
src/http2/huffman.zig          HPACK Huffman decode/encode
src/http2/generated_tables.zig GENERATED: static table + Huffman codes
src/http2/hpack.zig            integer/string primitives, dynamic table, decode/encode
src/http2/rfc7541_vectors.zig  GENERATED: RFC 7541 Appendix C conformance vectors
src/http2/settings.zig         SETTINGS codec + our advertised values
src/http2/stream.zig           RFC 9113 §5.1 state machine, stream table
src/http2/flow_control.zig     connection/stream windows
src/http2/connection.zig       connection driver: feed() inbound, flush() outbound
src/http2/server.zig           socket loop + dispatch onto the existing router
```

`http_server.zig` gains three things: an `enable_h2c` flag, the sniff (which runs
**before** the HTTP/1.1 request reader), and a handoff of the sniffed bytes to
`RequestBuffer` so nothing is lost.

### The trap this design exists to avoid

`RequestBuffer.readFullRequest` stops at the first `\r\n\r\n` — which the h2
preface contains at **byte 14**. Parsing HTTP/1.1 first would therefore consume
the preface *and* the frames that arrived in the same TCP segment, handing them
to `parseRequest` as a bogus body. `connection_reader.sniff()` reads one chunk,
classifies it, and hands every byte to whichever codec wins. The classification
must accept buffers **longer** than 24 bytes (a prior-knowledge client sends the
preface and its SETTINGS frame back-to-back); there is a regression test for
exactly that case.

## Testing

```bash
# unit + socket-level tests (module)
cd src/modules/custom_http_server && zig build test --summary all

# repo-wide gate (CI)
zig build test --summary all

# end-to-end with a real h2 client
zig build install:linux
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional/http2_test.py -v

# cross-platform compile check
zig test -lc --test-no-exec -target x86_64-windows-gnu src/modules/custom_http_server/src/test_runner.zig
zig test -lc --test-no-exec -target aarch64-macos        src/modules/custom_http_server/src/test_runner.zig
```

HPACK correctness is anchored on the RFC itself: `tools/gen_hpack_tables.py`
parses RFC 7541 Appendices A/B/C, refuses to emit if the RFC text and the
reference `hpack` implementation disagree, and generates both the Zig tables and
the test vectors (Appendix C.1 integers, C.2 representation examples, C.3–C.6
request/response sequences including eviction).

## Regenerating the HPACK tables

```bash
curl -sS -o /tmp/rfc7541.txt https://www.rfc-editor.org/rfc/rfc7541.txt
pip install hpack   # dev-time only; generated files are committed
python3 tools/gen_hpack_tables.py --rfc /tmp/rfc7541.txt \
  --out-tables  src/modules/custom_http_server/src/http2/generated_tables.zig \
  --out-vectors src/modules/custom_http_server/src/http2/rfc7541_vectors.zig
```
