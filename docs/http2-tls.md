# HTTP/2 over TLS (ALPN) in `custom_http_server`

Status: **contract + acceptance tests landed (test-first); the CLI flags are not wired
yet.** `tests/functional/http2_tls_test.py` is the spec in executable form and is expected
to be red until the integration commit lands. Companion to [`http2.md`](./http2.md) (h2c,
already shipped behind `--http2 h2c`).

Goal: serve HTTP/2 to **browsers**, the way Go's `http.Server` does it — one listener,
`NextProtos = ["h2", "http/1.1"]`, ALPN decides, both protocols share the same handlers.

## Why TLS at all

h2c unlocks HTTP/2 for *clients we choose*: `curl --http2-prior-knowledge`, nghttp2
tooling, sidecars, agents. Browsers are not on that list. Per RFC 9113 §3.2 a browser
uses HTTP/2 for an `https://` origin **only** when TLS ALPN selects the protocol name
`h2`; there is no browser-side h2c, ever.

The payoff is the reason HTTP/2 exists: browsers cap concurrent HTTP/1.1 connections per
origin (Chrome/Firefox ≈ 6), so a chatty app queues behind that cap. One h2 connection
multiplexes all of it and stops paying a TCP + TLS handshake per request. TLS is not an
end in itself — it is the precondition for browser h2.

## Why OpenSSL (not Zig std)

Verified on Zig 0.16: `std/crypto/tls.zig` exports a **client only** — no
`std.crypto.tls.Server`, no ALPN server API. So a std-only TLS server is not on the table.

* **OpenSSL via C bindings (chosen)** — the app already links `ssl`/`crypto` (libpq,
  libcurl) and the build already probes system libs / vendors per target.
  `custom_http_server` gains a link dependency (it links only libc today); Windows needs
  the OpenSSL DLLs (already in the CI vcpkg set), macOS needs `openssl@3` (already in CI).
* Vendor mbedTLS / BearSSL — a new vendored C library across three targets, the repo's
  known cross-compile pain, for no feature we need.
* Write TLS 1.3 in Zig — weeks of work plus a security-critical surface.

Because TLS is opt-in that dependency sits behind a build flag, so `custom_http_server`
stays libc-only when TLS is off. **Note for whoever runs the acceptance suite:** it points
at the ordinary `zig build install:linux` binary, so that binary must have TLS compiled
in — otherwise every TLS test fails with "the requested TLS mode was not honoured".

## One port; TLS and plaintext are mutually exclusive

There is deliberately **no `--tls-addr` / second port**. A listener is either TLS or
plaintext: absent the flags it is today's plaintext HTTP/1.1 (+ h2c behind `--http2 h2c`),
byte-identical; with a TLS flag it is TLS only. No sniffing to multiplex the two, because
that is a downgrade surface and a second code path to keep in sync forever. A plaintext
`GET` to a TLS listener fails (asserted by
`test_tls_and_h2c_are_mutually_exclusive_on_a_port`); a caller needing both runs two
processes on two ports.

## CLI contract

Parsed on the main `nalar` entry point, in the same loop as `--port` / `--static-dir` /
`--http2`:

```
--tls <cert.pem> <key.pem>   serve TLS using existing PEM files
--tls-selfsigned             generate (first run) / reuse the app-data cert, then serve TLS
```

* Both **off by default**; absent them, nothing about today's listeners changes.
* ALPN offered: `h2` **first**, then `http/1.1` — the order is the server's preference
  and why `curl --http2` lands on `2`.
* `--tls-selfsigned` prints the certificate path in the startup log; the tests parse the
  log rather than hardcoding the app-data directory.
* `--tls` with a missing/invalid cert or key → **non-zero exit**, message naming both the
  flag and the offending path.

One sharp edge the acceptance suite watches for: the arg loop has no `else` branch, so an
unrecognised flag is currently *silently ignored*. That turns "TLS not implemented yet"
into "server booted fine on plaintext while the https probe hangs". The test's readiness
probe therefore detects a plaintext answer on a TLS-requested boot and fails in ~3 s with
`the requested TLS mode was not honoured` instead of timing out.

## ALPN dispatch

One accept loop, one handshake, then the negotiated name picks the codec:

```
accept() → Stream(tls) → SSL_accept() → ALPN selected? ─┬─ "h2"         → http2/server.zig (existing driver)
                                                        └─ else/absent  → HTTP/1.1 path  (untouched)
```

h2 has no cleartext-only concepts, so the h2 driver is unchanged: the only difference
between h2c and h2-over-TLS is who owns the bytes underneath. A client that offers no
ALPN, or only `http/1.1`, gets the HTTP/1.1 path — no mid-connection fallback, and never
a silent downgrade after h2 was chosen.

## The `Stream` abstraction

Readers and writers used to call `read`/`write` on a raw `SocketFd`; TLS needs them over
an `SSL*`. The indirection is one tagged union
(`src/modules/custom_http_server/src/stream.zig`):

```zig
pub const Stream = union(enum) {
    plain: i32,        // the exact SocketFd the server already carries
    tls: *anyopaque,   // owned by the TLS layer; opaque here
    // read / writeAll / close dispatch per variant
};
pub const TlsOps = struct { read, write_all, close };  // registered once at startup
```

Two properties make this safe rather than clever. **(1)** The plain arm issues the same
syscalls as before — `std.posix.system.read/write` on POSIX, `winsock.recv/send` on
Windows (Winsock sockets are not in the UCRT fd table, so libc `read`/`write` fail on
them). HTTP/1.1 wire bytes are therefore identical; the byte-level tests (SSE chunk
framing, `toBytes`, static files) are the guard, not a convention. **(2)** The TLS arm is
an opaque pointer plus a function-pointer table, so `stream.zig` compiles before/without
the TLS module and the transport contract never names a crypto type — no import cycle, no
OpenSSL in the hot path's type surface.

`ConnectionReader`, `GinwaServer.sendToClient` and `http2/server.zig::serveConnection`
take a `Stream` instead of an fd; the pre-TLS call sites keep their fd wrapper, so nothing
outside the accept path changes shape.

## Certificates

**Self-signed on first run.** `--tls-selfsigned` generates, on first run only, an **EC
P-256** self-signed certificate with `SAN DNS:localhost, IP:127.0.0.1`, writes it plus its
key (mode **0600**) into the app data dir — `$XDG_DATA_HOME/nalar/tls/`, or
`%LOCALAPPDATA%\nalar\tls\` on Windows — and reuses it on every later run. No elevation,
no trust-store writes, no shared private key in the repo. `--tls <cert.pem> <key.pem>` is
the escape hatch for callers with their own PEM material (corporate CA, mkcert, a real
domain); it generates nothing.

The SAN pair is not cosmetic: the desktop app loads the UI from `localhost` in some
backends and `127.0.0.1` in others, and verification fails for whichever name is missing.
`test_tls_cert_san_matches_localhost` drops `-k` and verifies against both names with
`--cacert` — that is why the certificate contents are tested at all.

**Trusting it.** A browser or webview shows an interstitial for an untrusted cert unless
the host accepts it. Three hooks, one per backend, all already owned by the desktop app:

| Backend | Hook |
|---|---|
| WebView2 (Windows) | `ServerCertificateErrorDetected` |
| WKWebView (macOS) | `didReceiveAuthenticationChallenge` |
| WebKitGTK (Linux) | `load-failed-with-tls-errors` |

For a plain browser, print the path and a one-line "trust this cert once" hint — nothing
is installed system-wide.

## ⚠️ Ordering warning: land SSE-over-h2 *before* the UI moves to `https://`

This is the one way the feature can silently break the app.

Once ALPN negotiates `h2`, a browser uses h2 for **every** request on that origin —
including `EventSource`. Our SSE (and WebSocket) routes currently answer **501 over
HTTP/2** (`http2.md` known gap #1): `SseManager` keys clients by file descriptor, polls
that fd for EOF, and closes with `\r\n\r\n` chunk terminators — none of which maps onto
one fd carrying N streams. So the order is:

1. **Now:** TLS + ALPN + h2-over-TLS, default off, exercised on a scratch port. The
   webview keeps talking `http://`, so browsers stay on HTTP/1.1 and notice nothing.
2. **Mandatory step 2:** streaming over h2 — a per-stream sink in `SseManager` (the
   `WsManager.WriteFn` shape already in the repo), `END_STREAM` where the h1 path writes
   `0\r\n\r\n`, and the 501 goes away.
3. **Only then:** point the webview at `https://127.0.0.1:<port>` behind its own flag.

Flipping the UI to https at step 1 buys **nothing** — no h2 without step 2, no browser
benefit without h2 — and risks live updates. If someone wants to flip early, the honest
option is to keep the UI on `http://`.

## Verification

The acceptance suite boots the real binary against an isolated `nalar-func-*` tmpdir HOME,
never a fixed port (never 8081), and tears down in a `finally`. It spawns the binary
itself instead of using `FunctionalHarness.boot`, because boot's readiness probe is a
*plaintext* `GET /health`, which a TLS-only listener can never answer. Most tests pass
`-k`: the self-signed cert is by construction not in the CI trust store, and installing a
trust anchor is the webview's job, not the runner's — `-k` keeps "does this listener speak
TLS with real ALPN" separate from "does this machine trust this cert". Exactly one test
uses `--cacert` instead: the certificate-contents test.

```bash
zig build install:linux
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional/http2_tls_test.py -v
```

### Verifying by hand

```bash
# start with a self-signed cert; the log prints the cert path
./zig-out/bin/nalarcore-linux-x86_64 --port 8443 --tls-selfsigned

# ALPN h2  → prints "2"
curl -k --http2   -o /dev/null -w '%{http_version}\n' https://127.0.0.1:8443/health
# ALPN fallback → prints "200 1.1"
curl -k --http1.1 -o /dev/null -w '%{http_code} %{http_version}\n' https://127.0.0.1:8443/health
# certificate contents (both SANs must verify; note: no -k)
curl --cacert /path/to/cert.pem https://localhost:8443/health
curl --cacert /path/to/cert.pem https://127.0.0.1:8443/health
# plaintext on a TLS port must FAIL
curl http://127.0.0.1:8443/health

# unchanged defaults (no TLS flags): 1.1, and 2 with --http2 h2c
./zig-out/bin/nalarcore-linux-x86_64 --port 8080 --http2 h2c
curl -o /dev/null -w '%{http_version}\n' http://127.0.0.1:8080/health
curl --http2-prior-knowledge -o /dev/null -w '%{http_version}\n' http://127.0.0.1:8080/health
```

## Not in scope (phase 1)

No mTLS / client certificates and no HTTP/2 server push (`ENABLE_PUSH=0`, as in the h2c
work). No h2 for the static-file handler — `--static-dir` still writes HTTP/1.1 bytes
(h2c known gap #2, unchanged). No automatic trust-store installation: it needs elevation
and is a system-wide side effect a desktop app should not perform silently.

## References

* `docs/http2.md` — the h2c work this builds on (frames, HPACK, flow control, gaps).
* `docs/superpowers/plans/2026-09-11-http2-tls-alpn.md` — the implementation plan (T1–T9,
  risks).
* `tests/functional/http2_tls_test.py` — the executable contract.
* RFC 9113 §3.2 (ALPN `h2`).

---

## Implementation status (landed)

Verified end-to-end on this branch with the real binary:

```bash
nalar --port 8080 --tls-selfsigned
curl -k --http2   -w '%{http_version}' https://127.0.0.1:8080/health   # → 2   (200, real body)
curl -k --http1.1 -w '%{http_version}' https://127.0.0.1:8080/health   # → 1.1 (200)
openssl s_client -connect 127.0.0.1:8080 -alpn h2,http/1.1 -brief      # TLSv1.3, ALPN h2
```

| Piece | Where |
|---|---|
| OpenSSL server TLS + ALPN selection | `src/modules/custom_http_server/src/http2/tls.zig` (20 tests) |
| Self-signed cert (EC P-256, SAN localhost + 127.0.0.1, key 0600, reused) | `src/http2/tls_cert.zig` (8 tests) |
| `Stream` = plain socket \| TLS, with a registered op table | `src/stream.zig` (8 tests) |
| ALPN dispatch in the accept path (`h2` → h2 driver, else h1 over TLS) | `src/http_server.zig` (`enableTls`, the per-connection handshake) |
| `--tls <cert> <key>` / `--tls-selfsigned`, SIGPIPE ignored | `src/main.zig` |
| Static files over TLS | the `--static-dir` handler now receives the `Stream` instead of an fd |
| Acceptance tests | `tests/functional/http2_tls_test.py` (6/6) |

Design realities worth knowing:

* **Zig 0.16 has no TLS server** — `std.crypto.tls` is client-only, and even that
  client has **no ALPN support** (`grep -rn alpn /usr/lib/zig/std` → nothing), so
  the ALPN tests drive an OpenSSL client. This is why TLS links OpenSSL: the app
  already requires `ssl`/`crypto` for libpq + libcurl, so no new product
  dependency is introduced.
* **HTTP/1.1 and TLS are mutually exclusive per listener** (like Go's
  `ListenAndServeTLS`): the port is either plaintext (h1 + optional h2c) or TLS
  (h1 + h2 via ALPN). `--http2 h2c` and `--tls` therefore do not combine.

## Two blockers before the desktop UI can be served over https

Once ALPN negotiates `h2`, the browser uses h2 for **every** request on the
origin — including `EventSource` and every asset. Both are still phase-1 gaps:

1. **SSE over h2 answers 501** (and SSE over h1+TLS also answers 501, because the
   SSE manager writes chunked frames straight to the fd). Serving the UI over
   https today would silently kill live updates.
2. **Static files over h2 answer 404** — the `--static-dir` handler writes an
   HTTP/1.1 response; over h1+TLS that works (verified: `/app.css` → 200), but the
   h2 dispatcher has no h2-shaped static path yet, so the webview would load no
   assets at all over https.

Both are closed by the streaming/static work in
`2026-09-11-http2-custom-http-server.md` (T8 / T22). Until then: keep the desktop
app on `http://` and use TLS for API clients and browsers that only need the API.
