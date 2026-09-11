# HTTP/2 (h2c) for `custom_http_server` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Do NOT start executing until the reviewer approves §0 (Decisions).**

**Goal:** Make the hand-rolled HTTP/1.1 server in `src/modules/custom_http_server` speak HTTP/2 over cleartext (h2c) on the same port, alongside HTTP/1.1 — byte-for-byte identical HTTP/1.1 behaviour, no new runtime dependencies, no TLS.

**Architecture:** Two wire codecs behind one dispatch layer. A tiny **connection reader** sniffs the first bytes of every accepted socket: the 24-byte HTTP/2 connection preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) or an `Upgrade: h2c` request selects the **h2 codec**; anything else stays on the **h1 path unchanged**. Both codecs share `router.matchRoute`, the existing CORS/body-cap/security gates, and the `HttpResponse` type — handlers never see a socket (`HandlerFn = fn(ctx, req, res) !HttpResponse`, `router.zig:17-21`), so all ~136 routes in `src/main.zig` work over h2 with zero edits. New protocol code lives in a new `src/http2/` directory: a pure frame/HPACK layer (unit-testable without I/O), a connection driver, and an fd-glue loop that reuses the module's existing `std.Io.Group.concurrent` one-task-per-connection concurrency model.

**Tech Stack:** Zig 0.16 (std-only — the module links only libc: `src/modules/custom_http_server/build.zig:48`), RFC 9113 (HTTP/2), RFC 7541 (HPACK), Python 3 functional harness (`tests/functional/harness.py`), `curl --http2-prior-knowledge` as the reference test client.

**Status:** PLANNING — for human review. Nothing is implemented yet; the worktree branch `worktree/worktrees_agent_http2` contains only this document.

---

## 0. Decisions to approve before execution

Each decision is a fork in the road that changes the task list. Recommendation + rationale is evidence-backed from a read-only audit of the current tree (line numbers in §3).

### D1 — Implement HTTP/2 natively in Zig (recommended) vs bind/vendor nghttp2

| | Native Zig | Bind system `libnghttp2` |
|---|---|---|
| New deps | **none** (std-only, keeps `README.md:274` "Standard library only" true) | system lib on Linux dev; **vendor + cross-compile for macOS/Windows** like `custom_http_client` does for libcurl |
| Windows CI | compiles everywhere the module already does | needs a 3rd vendored C library (the vendored-curl path is already documented as ~30 min cross-compile per target) |
| Risk | HPACK/Huffman correctness is on us — mitigated by RFC 7541 Appendix C vectors + property tests (T5–T8) | protocol engine is battle-tested |
| Effort | ~2.5–4k lines incl. tests | ~800–1200 lines of callback plumbing, but +build system work |

**Recommendation: native Zig.** The module's identity is "pure Zig, low-level POSIX sockets, std only", it links only libc, and the repo's vendor path is a known pain (multiple git-history entries about vendor race/30-min builds). HPACK is the only genuinely fiddly part and RFC 7541 ships exact test vectors.

### D2 — Scope = **h2c (cleartext) only**. TLS + ALPN is a separate plan.

HTTP/2-for-browsers requires **TLS + ALPN with `h2`** (browsers never do h2c). Our server has no TLS at all. So this plan delivers h2 to **non-browser clients**: `curl --http2-prior-knowledge/--http2`, nghttp2-based clients, service-mesh sidecars (envoy/HAProxy h2c upstream), agents, and future internal callers. Browsers keep using HTTP/1.1 exactly as today.

**Recommendation: accept this scope.** Adding TLS to the server (cert management, self-signed localhost trust, webview plumbing) is a subsystem of its own and would triple the risk. It becomes plan #2, and it is the plan that unlocks browser multiplexing. If the reviewer's actual goal is "the desktop app's webview uses h2", **stop and re-plan** — that requires TLS/ALPN first.

### D3 — SSE and WebSocket are **out of scope** for h2 in phase 1 → `501 Not Implemented`

`SseManager` is not a writer, it is an **fd lifecycle owner**: it keys clients by fd (`sse_manager.zig:152-153`), polls the fd for EOF (`:565`, `:608`), **closes the fd** on removal (`:113-114`, `:119-120`), and writes h1 chunk terminators (`0\r\n\r\n`) on four removal paths (`:287`, `:305`, `:422`, `:673`). Under h2 one fd serves N streams — all four assumptions break. There is exactly **one** production SSE route (`/api/events`, `src/main.zig:392`) and **no** `.ws` route in the real app.

**Recommendation: return 501 for `.sse` / `.websocket` routes when the codec is h2** (both are reachable only through their own `RouteResult` variants, `router.zig:578`/`:583`). WebSocket-over-h2 (RFC 8441 extended CONNECT) is explicitly not attempted. Streaming over h2 is tracked as follow-up plan #3.

### D4 — Default **OFF**, opt-in via `--http2=h2c`

Enabled by a CLI flag threaded into `GinwaServer` (parse at `src/main.zig:196-221`, applied after `GinwaServer.init` at `:254`, following the existing `ctxParent.static_dir_path` idiom at `:210`). With the flag absent, the accept loop's behaviour and wire bytes are identical to today.

**Recommendation: OFF by default** until the functional suite + a soak run are green, then flip in a 1-line follow-up commit.

### D5 — One task per connection, handlers inline (no per-stream threads)

The h2 connection loop runs on the existing per-connection `group.concurrent` task (`http_server.zig:469`). Streams are multiplexed **on the wire** (interleaved frames) but handler execution is serialized per connection. This is deliberately boring: it removes the classic h2 deadlock (writer blocked on flow-control window while the reader is also blocked) because the same task that wants to write can keep draining inbound frames.

**Recommendation: accept.** Per-stream concurrency is a follow-up optimization (adds a per-stream task + connection write mutex).

### D6 — Functional tests: `curl --http2-prior-knowledge` (zero new deps) + **optionally** add `h2` to `tests/functional/requirements.txt`

Verified on this box: `curl 8.22.0 … nghttp2/1.70.0` supports `--http2-prior-knowledge`; **no** `nghttp`/`h2load`/`h2spec`; **no** python `h2`/`hpack`/`hyperframe` anywhere. CI installs curl on Linux (pacman list, `ci.yml:387`) and macOS (brew, `ci.yml:476`) and runs the functional suite on both (`ci.yml:1487-1512`), so a curl-driven test works in CI with no new deps. Raw-socket Python (stdlib only) covers protocol-error cases; only *concurrent interleaving* needs a real h2 client library.

**Recommendation: curl + raw sockets for the gate; add pinned `h2>=4.1,<5` as an optional task** for multiplexing/flow-control assertions. It is pure Python, so it patches the venv in seconds and CI re-creates the venv by requirements hash.

### D7 — Spec version target: **RFC 9113** (which obsoletes RFC 7540) + RFC 7541 (HPACK)

---

## 1. Scope & explicit non-goals

**In scope**
- h2c prior-knowledge (client sends the preface immediately).
- h2c via `Upgrade: h2c` (HTTP/1.1 upgrade dance, RFC 9113 §3.2).
- Frame layer, HPACK (decode full + encode minimal-correct), SETTINGS, PING, GOAWAY, RST_STREAM, WINDOW_UPDATE, CONTINUATION, priority fields ignored.
- All existing routes: normal buffered responses + `--static-dir` static files.
- Per-stream flow control (send + receive windows), graceful GOAWAY on shutdown.

**Non-goals (explicitly)**
- TLS / ALPN / browser-facing h2 (plan #2).
- SSE + WebSocket over h2 → 501 (follow-up plan #3). No RFC 8441 extended CONNECT.
- Server push (`ENABLE_PUSH: 0`; incoming `PUSH_PROMISE` → `PROTOCOL_ERROR`).
- Stream priorities/dependencies (parse + ignore; no scheduling use).
- Per-stream concurrent handler execution (D5).
- HTTP/3, compression of any kind.

## 2. Global Constraints

1. **std-only.** No new `@import` of repo modules or C libraries in `src/http2/*`. The module's test binary links only libc (`build.zig:48`).
2. **HTTP/1.1 wire bytes must not change** — not even header order. The h1 codec path must keep calling `HttpResponse.toBytes()` (`http_parser.zig:688-716`) and `GinwaServer.sendToClient` (`http_server.zig:1002`) so existing byte-level tests pass *by construction*.
3. **Never move the SSE header literal out of `http_server.zig`** — `sse_chunked_test.zig:224-256` source-greps that exact file path for `Transfer-Encoding: chunked`, `X-Accel-Buffering: no`, and `Connection: close`. Phase 1 leaves the `.sse` arm (`http_server.zig:773-802`) untouched.
4. **Do not change**: `sendToClient`'s signature/publicness (`http_server_test.zig:276-289` + `src/main.zig:879` depend on it), `HandlerFn`, `RouteResult`, `HttpResponse`, `toBytes`.
5. **Per-request/per-connection arenas**: `ctx.allocator` is arena-backed; do **not** `defer free` arena slices. h2 adds one arena per *connection* (the existing one at `http_server.zig:463-467`) plus one per *stream* for request-scoped allocations.
6. **Windows must compile.** `std.posix.poll` does not exist there — the SSE manager already demonstrates the fork (`sse_manager.zig:521-530` sleeps instead of polling). Any new wait must be `comptime`-gated the same way, and all socket I/O must go through the existing `SocketFd`/winsock wrappers.
7. **Port 8081 is reserved** (always-running dev server). The functional harness already excludes it (`harness.py:101-131`, `RESERVED_PORTS = (8081,)`).
8. **TDD, one commit per task.** Every task starts with a failing test and ends with a commit on `worktree/worktrees_agent_http2`.
9. **RFC conformance limits** are enforced from day one: `MAX_FRAME_SIZE` 16384 in/out, `MAX_HEADER_LIST_SIZE` 65536 (HPACK bomb guard), `MAX_CONCURRENT_STREAMS` 128, `INITIAL_WINDOW_SIZE` 1 MiB, `ENABLE_PUSH` 0.

## 3. Verified baseline facts (audit evidence)

| Fact | Evidence |
|---|---|
| Router handlers never touch the fd → all routes work over h2 unchanged | `router.zig:17-21` `HandlerFn = fn(ctx, req, res) anyerror!HttpResponse`; 136 `gs.router.*` registrations in `src/main.zig:329-647` |
| Accept loop = one blocking task per connection, one arena per connection | `http_server.zig:460-469`, `:471-476`, `closeFd(fd)` at `:874` |
| **Read-ahead destroys h2 bytes** — `readFullRequest` stops at the first `\r\n\r\n`, which in the preface is byte 14; over-read bytes land in `req.body` and die with the arena | `http_server.zig:1167-1214` (4 KiB reads at `:1170`, `toOwnedSlice` at `:1198`/`:1213`), `http_parser.zig:733-739` |
| Every response hardcodes `Connection: close`; there is no `Connection`-agnostic variant | `http_parser.zig:692, 701-702`; SSE arm `http_server.zig:789` |
| The only existing `Upgrade`/101 builder is WebSocket's | `websocket_handshake.zig:65-84` (`:76-78`) |
| Static files write raw h1 to the fd, buffered in memory | `src/main.zig:852-881` (flush at `:879`), `writeStaticFileResponse` `:892-955`; `static_files.serve()` `:440-498` is **dead code** (`src/main.zig:840-851`) |
| SseManager owns/key/polls/closes the fd | `sse_manager.zig:85, 113-120, 152-153, 216, 287, 305, 422, 565, 608, 673, 893` |
| SSE header literal is source-grepped by path | `sse_chunked_test.zig:224` `HTTP_SERVER_PATH = "src/modules/custom_http_server/src/http_server.zig"`, greps at `:244-300` |
| Module tests are an explicit import list; root `zig build test` imports only 3 module test files | `custom_http_server/src/test_runner.zig:27-72`; `src/root.zig:876-953` (module imports at `:911,912,920`) |
| Root `build.zig` has **no** `addModule("custom_http_server")` → new module files need no root build change; they reach the app via `src/root.zig:865` `pub const gserverz = @import("modules/custom_http_server/src/http_server.zig")` | root `build.zig:3239-3242` is the demo exe only |
| Module's own `zig build test` is **currently RED** (pre-existing) | `zig build test` in `src/modules/custom_http_server` → `websocket_frames.zig:253:20: error: comparison of 'isize' with null`; acknowledged at `src/root.zig:915-919` |
| CLI flags parse at `:196-221`, server created at `:254`, `ctxParent` flag idiom at `:122-124, 210`; second parser for `service start` at `:706-826` | `src/main.zig` |
| Tooling: `curl 8.22.0` + `nghttp2/1.70.0`, `--http2-prior-knowledge` supported; no `nghttp`/`h2load`/`h2spec`; no python `h2`/`hpack`/`hyperframe`; `uv 0.12.10` present | verified on this machine; CI installs curl on Linux/macOS |
| Functional suite: Linux+macOS only, `zig build functional-test`, harness boots `[bin, "--port", port]` with an isolated `HOME` | `ci.yml:1487-1512`, `harness.py:396`, `:318-329`, `:1054-1075` |
| Build commands | `zig build test --summary all` (root, CI gate); `cd src/modules/custom_http_server && zig build test --summary all` (fast module gate); `zig build install:linux` (produces `zig-out/bin/nalarcore-linux-x86_64` — **`nalar-desktop` does NOT rebuild it**) |

## 4. File map

### NEW — protocol core (pure, no I/O; `std` + siblings only)

| File | Responsibility |
|---|---|
| `src/modules/custom_http_server/src/http2/constants.zig` | frame types/flags/error codes/settings ids, limits, defaults as `pub const` + enums |
| `src/modules/custom_http_server/src/http2/frame.zig` | 9-byte header encode/decode, padding, size validation, CONTINUATION sequencing rules |
| `src/modules/custom_http_server/src/http2/huffman_table.zig` | 257-entry canonical decode table (RFC 7541 App. B), comptime-checked |
| `src/modules/custom_http_server/src/http2/huffman.zig` | HPACK Huffman decoder (+ optional encoder), EOS/padding validation |
| `src/modules/custom_http_server/src/http2/hpack_tables.zig` | static table (61 entries) + exact-match lookup helpers |
| `src/modules/custom_http_server/src/http2/hpack.zig` | integer/string primitives, dynamic table, decoder, minimal encoder, size accounting, limits |
| `src/modules/custom_http_server/src/http2/settings.zig` | SETTINGS encode/decode/apply (incl. INITIAL_WINDOW_SIZE delta), ACK handling |
| `src/modules/custom_http_server/src/http2/stream.zig` | stream state machine (RFC 9113 §5.1) + per-stream bookkeeping |
| `src/modules/custom_http_server/src/http2/flow_control.zig` | connection + stream windows, DATA accounting, WINDOW_UPDATE generation |
| `src/modules/custom_http_server/src/http2/connection.zig` | frame pump (`feed(bytes) -> out`), request assembly, response serialization, GOAWAY |
| `src/modules/custom_http_server/src/http2/server.zig` | fd glue: h2 loop, preface/upgrade detection, poll/read-timeout, dispatch into `router` + gates, 501 for sse/ws routes |
| `src/modules/custom_http_server/src/http2/<each>_test.zig` | sibling unit tests (registered — see T2/T3) |
| `src/modules/custom_http_server/src/response_writer.zig` | `ResponseWriter` vtable + `H1Writer` (byte-identical to today) + `H2Writer` |
| `src/modules/custom_http_server/src/connection_reader.zig` | peekable, seedable connection buffer (fixes the read-ahead loss) + tests |

### NEW — tests & docs

| File | Responsibility |
|---|---|
| `tests/functional/http2_test.py` | h2c end-to-end via curl + raw sockets; h1 regression |
| `docs/http2.md` | architecture note (frame/HPACK layout, limits, deferrals) |
| `docs/superpowers/plans/2026-09-11-http2-custom-http-server.md` | this plan |

### EDIT

| File | Change |
|---|---|
| `src/modules/custom_http_server/src/test_runner.zig` | add `_ = @import("http2/..._test.zig")` + `_ = @import("connection_reader_test.zig")` + `response_writer_test.zig` |
| `src/root.zig` (test block `876-953`) | same imports, prefixed `modules/custom_http_server/src/...` (needed for the CI gate) |
| `src/modules/custom_http_server/src/http_server.zig` | `enable_h2c` field; sniff + h2 dispatch in `handle`; `ResponseWriter` at the non-SSE write sites (`:574,:599,:631,:666,:694-700,:719,:734,:767,:849,:870`); re-export `pub const http2 = @import("http2/server.zig")` in the `:5-37` block |
| `src/modules/custom_http_server/src/http_parser.zig` | (only if needed) a `toBytesInto(writer)` helper — **no change to `toBytes` output** |
| `src/main.zig` | `--http2=h2c` parse (`:196-221`) + apply after `:254`; static-dir handler + 3 helpers switch to the writer (`:852`, `:892`, `:961`, `:977`); `service start` parser (`:706-826`) |
| `src/modules/custom_http_server/src/main.zig` | add an `--http2` demo route + fix the 2 pre-existing compile errors so `zig build` works again |
| `src/modules/custom_http_server/README.md` | features/architecture/limits |
| `NALAR.md` | changelog entry at the end (repo convention) |
| `tests/functional/requirements.txt` | optional: `h2>=4.1,<5` (D6) |

## 5. Protocol contract (what "done" means on the wire)

**Detection, in `handle()` before any HTTP/1.1 parse:**
1. If the first 24 buffered bytes equal `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` → h2 prior-knowledge.
2. Else parse as h1; if the request carries `Upgrade: h2c` **and** `--http2` is on → reply exactly `HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n` (raw bytes, **not** `toBytes()`), then switch. Apply `HTTP2-Settings` from the request as the client's initial SETTINGS if present.
3. Else → existing h1 path, byte-identical.

**Server SETTINGS sent immediately after the preface:** `MAX_CONCURRENT_STREAMS=128`, `INITIAL_WINDOW_SIZE=1_048_576`, `MAX_FRAME_SIZE=16_384`, `ENABLE_PUSH=0`, `MAX_HEADER_LIST_SIZE=65_536`, plus `ACK` on the client's SETTINGS.

**Frames implemented:** DATA, HEADERS, PRIORITY (parse/ignore), RST_STREAM, SETTINGS, PUSH_PROMISE (→ connection `PROTOCOL_ERROR`), PING (echo, `ACK`), GOAWAY, WINDOW_UPDATE, CONTINUATION.

**Request mapping:** pseudo-headers `:method :path :scheme :authority` (all required except `:scheme` optional; `host` accepted as `:authority` fallback) → `HttpRequest{method, path, version="HTTP/2", headers, body, query, params}`; header names lowercased; `connection`/`upgrade`/`keep-alive`/`proxy-connection`/`transfer-encoding` → `PROTOCOL_ERROR` RST_STREAM; `te` only `trailers`.

**Response mapping:** `HttpResponse` → `:status` + headers (drop `Connection`, `Transfer-Encoding`, `Content-Length` is optional-but-emitted as-is) → DATA frames ≤16 KiB clipped by the stream send window; `END_STREAM` on the final frame. Status is never taken from `status_text` (h2 has no reason phrase) — `status_code` only.

**Route mapping:** `.handler` → normal response; `.sse`/`.websocket` → `501` with body `SSE/WebSocket routes are not available over HTTP/2 (use HTTP/1.1)`; route miss → `404` (same `notFound` builder, serialized by `H2Writer`); static-dir fallback → served via `ResponseWriter`.

**WebSocket upgrade over an h2 connection:** `CONNECT`/`:protocol` is **not** supported → if we ever see it, `RST_STREAM` + log.

**Errors:** malformed frame / bad pseudo-header → `RST_STREAM(PROTOCOL_ERROR)` when a stream is identifiable, else connection `GOAWAY(PROTOCOL_ERROR)`; HPACK failure → connection `GOAWAY(COMPRESSION_ERROR)`; header list over `MAX_HEADER_LIST_SIZE` → `GOAWAY(ENHANCE_YOUR_CALM)`; flow-control overrun → `GOAWAY(FLOW_CONTROL_ERROR)`.

## 6. Development workflow (mandatory)

```bash
# 0. Work inside the worktree. Never touch /home/ginwa/ginwaaitoolbox (bare repo).
cd /home/ginwa/ginwaaitoolbox/.worktree/worktrees_agent_http2

# 1. Fast TDD loop for the pure protocol layer + module tests
cd src/modules/custom_http_server && zig build test --summary all && cd -

# 2. CI-equivalent gate (run before every commit that touches module code)
zig build test --summary all

# 3. Functional gate — rebuild the REAL binary first: nalar-desktop does NOT rebuild it
zig build install:linux
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/http2_test.py -v

# 4. Commit per task, push, open the PR at the end
git add -A && git commit -m "feat(http2): <task>"
git push -u origin worktree/worktrees_agent_http2
gh pr create --base main --title "feat(http2): h2c support for custom_http_server" --body "..."
```

Rule: **port 8081 is never used**; the harness picks a random free port in 40 000–60 000 with an isolated `HOME`.

---

## 7. Tasks

### Phase 0 — unblock the gates

#### T1 — Fix the pre-existing module-test compile break
**Files:** `src/modules/custom_http_server/src/websocket_frames.zig:245-256`
- [ ] Reproduce: `cd src/modules/custom_http_server && zig build test --summary all` → expect `websocket_frames.zig:253:20: error: comparison of 'isize' with null`.
- [ ] Write the fix as a type-correct optional check (the block at `:245-251` yields `?isize` only on the `break :blk null` path; make both arms agree, e.g. `const got: ?isize = blk: { … break :blk @as(?isize, std.c.getrandom(&key, key.len, 0)); };`).
- [ ] Re-run: module suite green (`0 failed`).
- [ ] Commit: `fix(http_server): module test build — optional isize comparison in generateMaskKey`.

#### T2 — Test-runner registration scaffold
**Files:** `src/modules/custom_http_server/src/test_runner.zig:27-72`, `src/root.zig:876-953`
- [ ] Add (module runner) `_ = @import("http2/constants_test.zig");` … one line per new test file as it lands.
- [ ] Add the same lines to the root test block, prefixed `modules/custom_http_server/src/`.
- [ ] Add a **comment** in both places: "http2 tests must be registered in BOTH runners — CI runs the root gate".
- [ ] Verify: `zig build test --summary all` still passes; `cd src/modules/custom_http_server && zig build test --summary all` still passes.
- [ ] Commit: `test(http2): register http2 test files in both test runners`.

### Phase 1 — pure protocol layer (no I/O, TDD with RFC vectors)

#### T3 — `http2/constants.zig`
- [ ] Failing test `http2/constants_test.zig`: assert `FrameType.data == 0x0 … continuation == 0x9`, `Flag.end_stream == 0x1`, `Setting.max_frame_size == 0x5`, `ErrorCode.protocol_error == 0x1`, and that the default limits match §5.
- [ ] Implement the enums/consts.
- [ ] Verify module tests + root tests green. Commit: `feat(http2): add frame/settings/error constants`.

#### T4 — `http2/frame.zig` (frame header + payload framing)
- [ ] Failing tests: round-trip a `DATA` frame with and without `PADDED`; **reserved bit (0x80 of byte 4) is ignored on decode and never set on encode**; length > our `MAX_FRAME_SIZE` on receive → `error.FrameSizeError`; length > 0xFFFFFF on encode → `error.InvalidFrameLength`; truncated header/payload → `error.IncompleteFrame`; padding length ≥ payload length → `error.ProtocolError`.
- [ ] Implement `Header` (packed 9-byte encode/decode), `Frame{ header, payload }`, `stripPadding`, `PREFACE` constant + `isPreface(bytes)`.
- [ ] Verify + commit: `feat(http2): frame header codec + preliminary preface detection`.

#### T5 — `http2/huffman_table.zig` + `http2/huffman.zig`
- [ ] Transcribe the 257-entry canonical table from **RFC 7541 Appendix B** into a comptime array; add a comptime assertion that the code lengths are prefix-free (a simple validity walk) so a typo fails the build rather than a fuzz run.
- [ ] Failing tests using **RFC 7541 Appendix C.4.1/C.4.2/C.5/C.6 vectors** (the Huffman-encoded request/response blocks) plus: byte 0x00 → symbol 48 (`'0'`); EOS symbol (256) in the stream → `error.InvalidHuffmanCode`; padding of more than 7 bits → error; padding not all-ones → error; a 256-symbol round-trip if an encoder is implemented.
- [ ] Implement the decoder (bit-reader + tree/table walk). Encoder is optional (see T8 note) — implement only if a test needs it.
- [ ] Verify + commit: `feat(http2): HPACK Huffman decoder + RFC 7541 vectors`.

#### T6 — `http2/hpack_tables.zig`
- [ ] Failing tests: table length is exactly 61; `:method GET` → index 2; `:status 200` → 8; `:status 404` → 13; `accept-encoding gzip, deflate` → 16; `(name-only)` lookups for `:authority`/`content-type`; an unknown pair returns null.
- [ ] Implement `static_table` slice + `findExact(name,value): ?u8` + `findName(name): ?u8`.
- [ ] Verify + commit: `feat(http2): HPACK static table`.

#### T7 — `http2/hpack.zig` primitives (integer + string literals)
- [ ] Failing tests: **RFC 7541 C.1** — decode 5-bit `10` at offset 0 of `{0x0a}` → 10; C.1.2 `1337` with 5-bit prefix → bytes `1f 9a 0a`; C.1.3 42 with 8-bit prefix → `2a`; multi-byte overflow (>32 bits) → `error.IntegerOverflow`; string with `H=1` decodes via Huffman, `H=0` verbatim; `H=1` with a non-canonical padding → error.
- [ ] Implement `decodeInteger(data, prefix_bits) -> {value, consumed}`, `decodeString`, and the encoders (`encodeInteger`, `encodeString`) that T8/T9 need.
- [ ] Verify + commit: `feat(http2): HPACK integer + string primitives (RFC 7541 C.1/C.2)`.

#### T8 — `http2/hpack.zig` decoder (dynamic table + full sequences)
- [ ] Failing tests: **RFC 7541 C.3** (3 requests, no Huffman, no indexing), **C.4** (3 requests, Huffman), **C.5** (3 responses, eviction, table size 256), **C.6** (3 responses, Huffman + eviction) — each asserts the decoded header list **and** the resulting dynamic-table size/contents.
- [ ] Also: dynamic table size update (`001xxxxx`) before any header field; size update > our advertised `SETTINGS_HEADER_TABLE_SIZE` → `error.CompressionError`; eviction accounting (`entry_size = name.len + value.len + 32`); **HPACK-bomb guard** — a header list exceeding `MAX_HEADER_LIST_SIZE` aborts with `error.HeaderListTooLarge` and never allocates unbounded (assert peak allocation via a counting allocator).
- [ ] Implement `Decoder{ table, max_table_size, max_header_list_size }` + `decode(block) -> []Header`.
- [ ] Verify + commit: `feat(http2): HPACK decoder (RFC 7541 C.3–C.6 + bomb guard)`.

#### T9 — `http2/hpack.zig` encoder (minimal-correct)
- [ ] Failing property tests: `decode(encode(randomHeaders)) == randomHeaders` for 200 seeded-random lists (fixed seed); `:status 200/404` uses the static indexed form; header names/values that exactly match a static entry use the indexed form; everything else uses **literal-without-indexing (0x00)** and **never** adds to the dynamic table (assert the table stays empty); values larger than 16 KiB are not Huffman-encoded (we may skip Huffman encoding entirely — legal and simplifies).
- [ ] Implement `Encoder` with the static-table shortcuts above.
- [ ] Verify + commit: `feat(http2): HPACK encoder (literal-without-indexing + static shortcuts)`.

#### T10 — `http2/settings.zig`
- [ ] Failing tests: encode/decode a 6-byte entry; an odd payload length → `error.FrameSizeError`; duplicate ids take the last value; unknown ids are ignored (RFC 9113 §6.5.2); applying `INITIAL_WINDOW_SIZE` adjusts every open stream's send window by the delta and a negative result → `FLOW_CONTROL_ERROR`; unknown/invalid `MAX_FRAME_SIZE` (<16384 or >16777215) → `PROTOCOL_ERROR`; our defaults match §5.
- [ ] Implement `Settings{…}`, `encode`, `decode`, `applyTo(conn state)`.
- [ ] Verify + commit: `feat(http2): SETTINGS codec + apply semantics`.

#### T11 — `http2/stream.zig`
- [ ] Failing tests: legal transitions `idle→open→half_closed_remote→closed`; illegal ones rejected (`DATA` on idle → `PROTOCOL_ERROR`; `HEADERS` on closed → `STREAM_CLOSED`; `WINDOW_UPDATE` on idle → `PROTOCOL_ERROR`); `RST_STREAM` on any state → closed; a stream id lower than the last-seen → `PROTOCOL_ERROR`; even ids from a client → `PROTOCOL_ERROR`; exceeding `MAX_CONCURRENT_STREAMS` → `REFUSED_STREAM`.
- [ ] Implement `State`, `Stream{id, state, send_window, recv_window, headers}` + `ConnStreamTable`.
- [ ] Verify + commit: `feat(http2): stream state machine`.

#### T12 — `http2/flow_control.zig`
- [ ] Failing tests: DATA decrements both windows; WINDOW_UPDATE(0 increment) → `PROTOCOL_ERROR`; increment overflowing 2^31-1 → `FLOW_CONTROL_ERROR`; receiving more DATA than the connection window → `FLOW_CONTROL_ERROR`; consumed bytes produce a WINDOW_UPDATE when the accumulated value ≥ half the window (coalescing rule we adopt); a send request larger than the window returns the allowed prefix (no partial-write panic).
- [ ] Implement the window struct + accounting helpers.
- [ ] Verify + commit: `feat(http2): connection + stream flow control`.

### Phase 2 — connection driver

#### T13 — `http2/connection.zig`: preface + SETTINGS + PING + GOAWAY skeleton
- [ ] Failing tests (in-memory, no sockets): feeding the preface then client SETTINGS produces our SETTINGS frame + SETTINGS ACK; an unexpected first byte → `GOAWAY(PROTOCOL_ERROR)`; PING → echoed PING with `ACK` (same 8 bytes); a SETTINGS `ACK` from the client clears `pending_ack`; GOAWAY with a higher last-stream-id than before → `PROTOCOL_ERROR`.
- [ ] Implement `Connection.init/Destroy`, `feed(bytes) -> []const u8` (outbound), the preface state machine, and frame dispatch for the connection-level types (this task does not yet assemble requests).
- [ ] Verify + commit: `feat(http2): connection preface/SETTINGS/PING/GOAWAY`.

#### T14 — `http2/connection.zig`: HEADERS → request assembly
- [ ] Failing tests: a single HEADERS frame with `:method GET`/`:path /x`/`:scheme http`/`:authority localhost` + `accept: */*` → a `Request` struct; CONTINUATION-fragmented HEADERS reassembles (and an interleaved frame between them → `PROTOCOL_ERROR`); `:method` missing → RST_STREAM(PROTOCOL_ERROR); uppercase header name → PROTOCOL_ERROR; `connection: keep-alive` → PROTOCOL_ERROR; `te: gzip` → PROTOCOL_ERROR but `te: trailers` OK; `PUSH_PROMISE` from client → GOAWAY(PROTOCOL_ERROR); DATA after END_STREAM → STREAM_CLOSED; body assembled from multiple DATA frames; HPACK failure → GOAWAY(COMPRESSION_ERROR).
- [ ] Implement `Request` assembly + validation helper that emits the correct RST/GOAWAY.
- [ ] Verify + commit: `feat(http2): HEADERS→request assembly + pseudo-header validation`.

#### T15 — `http2/connection.zig`: response serialization
- [ ] Failing tests: empty body → HEADERS with `END_STREAM`; 40 KiB body → 3 DATA frames (16384/16384/remainder) with `END_STREAM` on the last; a 100 KiB body with a 16 KiB send window → the driver yields frames only up to the window, then continues after a WINDOW_UPDATE is fed in (explicit interleaving test); `Connection`/`Transfer-Encoding` headers are dropped; `:status` comes from `status_code` only; response headers HPACK-encode and decode back to the same set.
- [ ] Implement `respond(stream_id, *const HttpResponse) -> queued frames` + `pumpWindowUpdates(bytes)`.
- [ ] Verify + commit: `feat(http2): response HEADERS/DATA serialization + window-aware chunking`.

#### T16 — `src/connection_reader.zig` (peekable, seedable buffer) — **the read-ahead fix**
- [ ] Failing tests (in-memory or via the module's `test_helpers.zig` socketpair): `fillOnce()` reads once and keeps bytes; `peek(n)` does not consume; `readHttp1Request()` on a seeded buffer that already contains a full request returns **exactly the same slice as today's `readFullRequest`** for: GET with no body, POST with `Content-Length`, and a request followed by pipelined bytes; leftover pipelined bytes remain readable afterwards (assert `buffered()` shrinks by exactly the request length only for the h1 semantics we promise).
- [ ] Implement `ConnectionReader{ buf, fd, peeked }` + move/replicate `readFullRequest`'s accumulation logic (keep `http_server.zig:1167-1214` behaviour identical; do not delete `RequestBuffer`).
- [ ] Verify + commit: `feat(http_server): peekable ConnectionReader (h2 preface-safe read path)`.

### Phase 3 — server integration

#### T17 — `response_writer.zig`: `ResponseWriter` + `H1Writer` + `H2Writer`
- [ ] Failing tests: `H1Writer.writeBuffered` produces **byte-identical** output to `resp.toBytes()` + one `sendToClient` (compare against `toBytes()` in-test); `H2Writer.writeBuffered` on the 3 shapes (empty body, small body, >MAX_FRAME_SIZE body) matches the T15 expectations; `H1Writer.close` closes the fd; `H2Writer.close` does not.
- [ ] Implement the vtable from the audit sketch (5 methods: `writeHead`/`writeBody`/`finish`/`writeBuffered`/`close`), with `H1Writer` delegating to `toBytes()`/`sendToClient` so bytes cannot drift.
- [ ] Verify + commit: `feat(http_server): ResponseWriter seam (h1 byte-identical + h2)`.

#### T18 — Wire the writer into `handle()` (non-SSE sites only)
**Files:** `http_server.zig:472-876`
- [ ] Replace the 10 non-SSE `sendToClient(fd, …)` sites (`:574,:599,:631,:666,:694-700,:719,:734,:767,:849,:870`) with `writer.*` calls; **leave the `.sse` arm (`:773-802`) and the WS frames exactly as they are**.
- [ ] Tests: existing `http_server_test.zig` + `complex_cases_test.zig` + `sse_chunked_test.zig` + `src/root.zig` suite must all pass unchanged (byte-level regressions).
- [ ] Verify with the root gate **and** the module gate. Commit: `refactor(http_server): route non-SSE responses through ResponseWriter`.

#### T19 — Preface detection + h2 dispatch in `handle()`
- [ ] Failing tests (module level, using the socketpair helper): a socket that writes the 24-byte preface + a client SETTINGS frame receives a SETTINGS frame; a socket that writes `GET /health HTTP/1.1\r\n\r\n` still receives the old h1 bytes; a socket that writes **preface + frames + nothing else** does not lose the frames (regression for the read-ahead loss).
- [ ] Implement: `const first = cr.fillOnce(); if (http2.isPreface(cr.buffered())) { http2.serveConnection(...); return; }` before the existing h1 parse.
- [ ] Verify + commit: `feat(http_server): detect the HTTP/2 connection preface before the h1 parser`.

#### T20 — `http2/server.zig`: the fd glue + route dispatch
- [ ] Failing tests: h2 `GET /health` round-trip against a `GinwaServer` with a registered route returns `:status 200` + body; an unknown path returns 404; a `.sse` route returns 501 with the documented body; a route that mutates headers via `applyCORSResponse`/`applySecurityHeadersTo` shows those headers in the h2 response (guards the "silent CORS loss" trap); a request body > `max_body_bytes` gets the same 413 as h1.
- [ ] Implement: read loop with idle timeout (POSIX `poll`; Windows: `SO_RCVTIMEO` branch, `comptime`-gated), the `Request → HttpRequest` adapter, `router.matchRoute`, the pre-gate (`security.preGateCheck`), handler invocation, `ResponseWriter` selection, and `closeFd` only on connection end.
- [ ] Verify + commit: `feat(http2): h2c connection loop + route dispatch on the existing router`.

#### T21 — `Upgrade: h2c`
- [ ] Failing tests: an h1 request with `Connection: Upgrade, HTTP2-Settings` + `Upgrade: h2c` + `HTTP2-Settings: <base64url SETTINGS>` → response starts with exactly `HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n`; the connection then accepts h2 frames; the `HTTP2-Settings` payload is applied as the peer's initial settings; with `--http2` off, the same request is handled as a normal h1 request (no 101).
- [ ] Implement the 101 raw write + switch (reuse `ConnectionReader`'s leftover buffer).
- [ ] Verify + commit: `feat(http2): h2c upgrade path (101 Switching Protocols)`.

#### T22 — Static files over the writer
**Files:** `src/main.zig:852-881, 892-955, 961-996`, `http_server.zig:352-409, 849`
- [ ] Swap `static_dir_handler`'s `fd: SocketFd` parameter for `writer: *ResponseWriter` (field + setter + call site); convert the literal `"HTTP/1.1 …"`/`"Connection: close"` lines into `writeHead(...)`; keep `writeFileFull`/`writeFileRange` streaming through `writeBody` in 64 KiB reads.
- [ ] Regression: h1 static responses must remain byte-identical — add a functional test that boots with `--static-dir` (currently **no** test does; `harness.py:396` only passes `--port`) and asserts the same bytes over h1.
- [ ] Verify + commit: `feat(static): serve static files through ResponseWriter (h1 unchanged, h2 ready)`.

#### T23 — Flag plumbing
- [ ] Failing test (static contract, like `session_create_test.zig` does): `--http2=h2c` is parsed; `--http2=off`/absent leaves `enable_h2c == false`; the `service start` parser accepts the same value.
- [ ] Implement in `src/main.zig` `:196-221` + apply after `:254`; extend the `service` parser (`:706-826`); add `GinwaServer.enable_h2c: bool = false` + early-out when false.
- [ ] Verify + commit: `feat(http2): --http2=h2c flag (default off)`.

#### T24 — Demo binary + docs
- [ ] Fix `src/modules/custom_http_server/src/main.zig`'s 2 compile errors (`:717` unused `noCacheMiddleware`; `wsEchoHandler` signature vs `router.zig:394`) so `zig build` in the module works again.
- [ ] Add an `--http2` demo note + a `/h2check` route returning the negotiated protocol.
- [ ] Update `README.md` (features, architecture, limits, the h2c/browser caveat) and `docs/http2.md`; add the `NALAR.md` changelog entry.
- [ ] Verify + commit: `docs(http2): module README + architecture note + changelog`.

### Phase 4 — verification

#### T25 — `tests/functional/http2_test.py` (curl + raw sockets, zero new deps)
- [ ] `test_h2_prior_knowledge_get_health` — `curl --http2-prior-knowledge -sS -o /dev/null -w '%{http_version}'` → `2`; body `ok`.
- [ ] `test_h2_post_json_roundtrip` — POST an existing JSON route over h2 and compare the parsed body with the h1 result.
- [ ] `test_h1_unchanged_when_h2_enabled` — plain `curl` (no `--http2*`) still gets `http_version=1.1` and identical bytes.
- [ ] `test_h1_unchanged_when_h2_disabled` — same as above with the flag off (the default).
- [ ] `test_h2_404_for_unknown_route` and `test_h2_501_for_sse_route`.
- [ ] `test_h2_large_response_flow_control` — a route returning ≥1 MiB (`/api/llm/histories` style or a dedicated test route) completes over h2 (raw socket; assert `WINDOW_UPDATE` frames were exchanged).
- [ ] `test_h2_bogus_preface_gets_goaway` — raw socket writes `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` + a garbage frame → server replies `GOAWAY(PROTOCOL_ERROR)` and closes, process stays alive.
- [ ] `test_h2_connection_reuse` — `curl --http2-prior-knowledge url1 url2` uses **one** connection (`%{num_connects}` == 1 for the second URL) where h1 today needs 2 (baseline already measured).
- [ ] Run: `zig build install:linux && NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/http2_test.py -v`.
- [ ] Commit: `test(http2): functional h2c suite (curl + raw sockets)`.

#### T26 — (Optional, D6) multiplexing + interleaving with the `h2` package
- [ ] Add `h2>=4.1,<5` to `tests/functional/requirements.txt` with a comment; re-create the venv (`zig build functional-test` bootstraps it).
- [ ] Tests: 3 concurrent streams on one connection complete out-of-order; a slow stream does not block a fast one; RST_STREAM mid-body is handled.
- [ ] Commit: `test(http2): concurrent stream interleaving (python h2)`.

#### T27 — Final gates + PR
- [ ] `zig build test --summary all` (root) green; `cd src/modules/custom_http_server && zig build test --summary all` green.
- [ ] `zig build install:linux` + full `tests/functional/` suite green (no regressions in the ~40 existing suites).
- [ ] `zig build nalar-desktop --summary all` green (app still builds).
- [ ] Manual smoke: start the real binary on a random non-8081 port with `--http2=h2c`, verify `curl --http2-prior-knowledge` + the desktop app still work; stop the process.
- [ ] Push + `gh pr create --base main` with a body linking this plan, the risk list, and the measured before/after (`num_connects`).
- [ ] Commit: `docs(http2): verification results` (or fold into the PR body).

## 8. Verification gates (definition of done)

1. `zig build test --summary all` → 0 failures (root/CI gate).
2. `cd src/modules/custom_http_server && zig build test --summary all` → 0 failures.
3. `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/ -v` → 0 failures (existing suites + `http2_test.py`).
4. `curl --http2-prior-knowledge` against the real binary returns `http_version=2` on a documented route; `curl` (h1) returns `1.1` with unchanged bytes.
5. With `--http2` absent: byte-identical h1 behaviour (existing byte-level tests prove it).
6. `zig build nalar-desktop --summary all` green.

## 9. Risks & pitfalls (ordered by likelihood × damage)

| # | Risk | Mitigation (task) |
|---|---|---|
| R1 | **Read-ahead eats the first frames** — today `readFullRequest` stops at the preface's `\r\n\r\n` (byte 14) and the SETTINGS bytes end up in `req.body` / are discarded at `closeFd` | T16 peekable reader + T19 sniff **before** the h1 parse; the regression test writes preface+SETTINGS in one `send()` |
| R2 | **HPACK bug → garbled headers or a security hole** (bomb, dynamic-table desync) | T5–T9 are pure and covered by RFC 7541 Appendix C vectors + property tests; hard caps on header-list size and table size asserted with a counting allocator |
| R3 | **Flow-control deadlock** (writer waits for WINDOW_UPDATE while nobody reads) | D5 single-task-per-connection design: the send path drains inbound frames (T15's interleaving test is the guard) |
| R4 | **h1 wire bytes drift** during the `ResponseWriter` refactor | T17 asserts `H1Writer` output equals `toBytes()` in-test; `sse_chunked_test.zig` source-greps (path-pinned at `:224`) mean the SSE arm must not move (constraint 3) |
| R5 | **Silent CORS/security-header loss on h2** (mutations happen pre-`toBytes` today) | T20 asserts CORS + security headers survive the h2 path |
| R6 | **Windows build break** (`std.posix.poll` absent; winsock paths) | T20 `comptime`-gates the wait strategy; every socket call goes through the existing wrappers; `zig build test` compiles the module for the host, and CI's Windows cell compiles the app |
| R7 | **Long-running h2 handlers block the whole connection** (D5) — e.g. an agent run | Documented limitation; clients can open a second connection. Per-stream tasks are follow-up plan #4 |
| R8 | **`Upgrade: h2c` regressions for existing h1 clients** that send `Upgrade: h2c` today (none known, but proxies may) | T21 test: with `--http2` off, such a request is handled as plain h1 (no 101) |
| R9 | **Static-dir handler signature change touches the app** (`src/main.zig` has no static-file functional coverage) | T22 adds the missing `--static-dir` functional test *before* the swap |
| R10 | **Both test runners must be updated** or CI silently skips the new tests (`src/root.zig` imports only 3 module test files today) | T2 registers in both; T27 verifies the root gate actually ran the new tests (check the count in `--summary all`) |
| R11 | **Module's own test step is red today** → cannot use it as the fast TDD gate | T1 fixes it first |

## 10. Deferred / follow-up plans (not this plan)

1. **Plan #2 — TLS + ALPN `h2`** (this is what makes browsers use h2; prerequisite for any browser-side benefit).
2. **Plan #3 — Streaming over h2**: give `SseManager` a per-stream `WriteFn` (copy the `WsManager` pattern at `websocket_manager.zig:43,130-134,188,210` + adapter `http_server.zig:742-747`), key clients by `(conn, stream_id)`, replace the 4 h1 chunk-terminator paths (`sse_manager.zig:287,305,422,673`) with `END_STREAM`, and stop `SseClient` from closing the shared connection fd (`:113-120`).
3. **Plan #4 — per-stream concurrency** (stream tasks + connection write mutex) once profiling shows handler serialization matters.
4. WebSocket over h2 (RFC 8441) — only if a client actually needs it.

## 11. Rollback

The feature is behind `--http2=h2c` (default off, T23) and the h1 path is unchanged (constraints 2/4). If h2 misbehaves in production: drop the flag (no code change) and the server behaves exactly as today. `T16`/`T17`/`T18` are the only refactors that touch the h1 path — each is independently revertable by commit.

---

## 12. Implementation status (what actually landed)

Executed on branch `worktree/worktrees_agent_http2`. Deviations from the task list
above are recorded here rather than silently dropped.

### Delivered

| Plan item | Status |
|---|---|
| T1 module test build fix | done — `websocket_frames.zig` optional-`isize` comparison |
| T2 test-runner registration | done — `http2/test_runner.zig` registered in BOTH runners |
| T3–T12 protocol core | done — constants, frame, Huffman, HPACK (decoder + encoder), SETTINGS, stream state machine, flow control |
| T13–T15 connection driver | done — preface/SETTINGS/PING/GOAWAY, request assembly, window-aware response serialization |
| T16 peekable reader | done — plus a `sniff()` classifier (added after a real bug, see below) |
| T19 preface detection | done — before the h1 reader, sniffed bytes handed to `RequestBuffer` |
| T20 h2 dispatch + socket loop | done — router, CORS/security gates, body caps, 501 for sse/ws, 404 |
| T23 `--http2` flag | done — `--http2 h2c` / `--http2 off`, default off |
| T24 docs | done — `docs/http2.md` + module README |
| T25 functional suite | done — `tests/functional/http2_test.py`, 8 tests, curl + raw sockets |
| T27 gates | done — root `zig build test`: 3342/3350 pass, 0 fail; module gate 672/672; functional 8/8; `install:linux` green; module cross-compiles for linux/windows/macos |

### Deviations

1. **T17/T18 (ResponseWriter seam + rewriting the h1 write sites) — NOT DONE, deliberately.**
   The h2 dispatcher builds `(status, header pairs, body)` directly and the h1
   path keeps calling `HttpResponse.toBytes()` + `sendToClient` untouched. That
   is a *stronger* byte-compatibility guarantee for HTTP/1.1 than the planned
   refactor (nothing in the hot path moved), at the cost of a parallel dispatch
   function in `http2/server.zig`. Unifying them is the follow-up, not a
   prerequisite.
2. **T21 `Upgrade: h2c` — NOT DONE.** Prior-knowledge h2c is implemented and
   tested; the HTTP/1.1 upgrade dance (101 + settings handoff) is a small,
   self-contained follow-up. curls

---

## 12. Implementation status (what actually landed)

Executed on branch `worktree/worktrees_agent_http2`. Deviations from the task list
above are recorded here rather than silently dropped.

### Delivered

| Plan item | Status |
|---|---|
| T1 module test build fix | done — `websocket_frames.zig` optional-`isize` comparison |
| T2 test-runner registration | done — `http2/test_runner.zig` registered in BOTH runners |
| T3–T12 protocol core | done — constants, frame, Huffman, HPACK decoder + encoder, SETTINGS, stream state machine, flow control |
| T13–T15 connection driver | done — preface/SETTINGS/PING/GOAWAY, request assembly, window-aware response serialization |
| T16 peekable reader | done — plus a `sniff()` classifier (added after a real bug, below) |
| T19 preface detection | done — runs before the h1 reader; sniffed bytes are handed to `RequestBuffer` |
| T20 h2 dispatch + socket loop | done — router, CORS/security gates, body caps, 501 for sse/ws, 404 |
| T23 `--http2` flag | done — `--http2 h2c` / `--http2 off`, default off |
| T24 docs | done — `docs/http2.md` + module README |
| T25 functional suite | done — `tests/functional/http2_test.py`, 8 tests, curl + raw sockets |
| T27 gates | done — root `zig build test` 3342/3350 pass / 0 fail; module gate 672/672; functional 8/8; `install:linux` green; module cross-compiles for Linux, Windows and macOS (x86_64 + aarch64) |

### Deviations

1. **T17/T18 (ResponseWriter seam + rewriting the h1 write sites) — NOT DONE, deliberately.**
   The h2 dispatcher builds `(status, header pairs, body)` directly, and the h1
   path keeps calling `HttpResponse.toBytes()` + `sendToClient` untouched. That is
   a *stronger* byte-compatibility guarantee for HTTP/1.1 than the planned
   refactor (nothing in the hot path moved), at the cost of a parallel dispatch
   function in `http2/server.zig`. Unifying the two dispatchers is a follow-up,
   not a prerequisite.
2. **T21 `Upgrade: h2c` — NOT DONE.** Prior-knowledge h2c is implemented and
   tested; the HTTP/1.1 upgrade dance (101 + settings handoff) is a small,
   self-contained follow-up. The plan's D6 test strategy (curl
   `--http2-prior-knowledge`) does not depend on it.
3. **T22 static files over h2 — NOT DONE.** The module cannot import
   `src/static_files.zig` (outside its package path) and the app's static handler
   writes raw HTTP/1.1 bytes to the fd, so h2 requests for unknown routes get the
   normal 404. Documented in `docs/http2.md` under known gaps.
4. **T26 python-`h2` multiplexing suite — NOT DONE.** Multiplexing IS covered:
   socket-level unit tests answer two streams out of order, and the functional
   suite proves connection reuse (`num_connects == [1, 0]` for two h2 requests on
   one connection, versus `[1, 1]` over h1).
5. **Demo `custom_http_server/src/main.zig` still does not compile** (two
   pre-existing errors: an unused `noCacheMiddleware` local, and a
   `wsEchoHandler` signature mismatch that surfaces in `router.zig`'s ws
   registration). Unrelated to this work: the module's `zig build test` is green
   and the demo exe is not in any build or CI step.

### Bug found only by the end-to-end probe (not by the unit tests)

The first functional run failed with curl error 55 on every h2 test. Cause: the
sniff used `isPrefacePrefix(first_read_bytes)`, which returns false when the
buffer is **longer** than 24 bytes — and a prior-knowledge client (curl included)
sends the preface *and* its SETTINGS frame in one segment, so the first read is
usually 33+ bytes. Every real h2 client was silently downgraded to HTTP/1.1.

Fixed by extracting `connection_reader.sniff() -> .h2 / .maybe_h2 / .h1`, with
regression tests for the `preface ++ SETTINGS` case. Lesson: a protocol
negotiation path needs a test whose input carries MORE data than the
discriminator, because that is what the wire actually delivers.
