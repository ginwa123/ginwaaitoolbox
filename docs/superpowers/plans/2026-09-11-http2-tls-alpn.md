# HTTP/2 over TLS (ALPN) — implementation plan

> **Status: PLAN FOR REVIEW.** Companion to `2026-09-11-http2-custom-http-server.md`
> (h2c, shipped in #449). Read §0 before executing anything.

**Goal:** serve HTTP/2 to **browsers**, the way Go's `http.Server` does it — one
listener, `NextProtos = ["h2", "http/1.1"]`, ALPN decides, both protocols share
the same handlers.

**Architecture:** terminate TLS in front of the existing accept loop, then let the
negotiated ALPN protocol choose the codec (h2 driver or the untouched HTTP/1.1
path). Requires an I/O indirection so the readers/writers can run over a `TLS*`
stream instead of a raw `SocketFd`.

---

## 0. Decisions to approve (and one ordering constraint that can break the app)

### D1 — TLS implementation: **OpenSSL** (recommended) — Zig std has no TLS server

Verified on this box (Zig 0.16): `std/crypto/tls.zig` exports **`Client` only** —
there is no `std.crypto.tls.Server` and no ALPN server API. So a std-only TLS
server is not an option today. Choices:

| Option | Cost |
|---|---|
| **OpenSSL via C bindings** (recommended) | The app **already links** `ssl`/`crypto` (libpq, libcurl) and the build already probes/vendors them per target. `custom_http_server` would gain a link dependency (it currently links only libc). Windows needs the OpenSSL DLLs (already in the CI vcpkg set), macOS needs `openssl@3` (already installed in CI). |
| Vendor mbedTLS / BearSSL | A new vendored C library across 3 targets — the repo's known cross-compile pain. |
| Write TLS 1.3 in Zig | Weeks of work plus a security-critical surface. Not proposed. |

**Recommendation: OpenSSL**, and keep it behind a build flag (`-Dtls=openssl`) so
`custom_http_server` stays libc-only when TLS is off.

### D2 — ⚠️ Ordering: **SSE-over-h2 must land BEFORE the desktop UI is served over TLS**

Once ALPN negotiates `h2`, the browser uses h2 for **every** request on that
origin — including `EventSource`. Our SSE routes currently answer **501 over h2**
(phase-1 scope decision in #449). So flipping the desktop app to `https://`
*before* streaming-over-h2 exists would **break live updates in the app**.

Therefore:
1. **Step 1 (this plan, part A):** TLS + ALPN + h2-over-TLS, *default OFF*, with
   curl/nghttp2/browser testing against a scratch port.
2. **Step 2 (part B, mandatory before the app switches):** streaming over h2 —
   `SseManager` gains a per-stream sink (the `WsManager.WriteFn` shape already in
   the repo), the four h1 chunk-terminator paths become `END_STREAM`, and the SSE
   route stops returning 501 for h2 clients.
3. **Step 3:** point the webview at `https://127.0.0.1:<port>` behind a flag.

If the reviewer wants the browser benefit *without* step 2 first, the only honest
option is to keep the UI on `http://` (then browsers stay on h1 and nothing
changes) — i.e. TLS alone buys nothing for the app.

### D3 — Certificate provisioning for a localhost desktop app

The webview must **trust** the cert or it shows an interstitial. Options:

| Option | Notes |
|---|---|
| **Self-signed cert generated on first run, stored in the app data dir, and accepted by the webview's cert-error hook** (recommended) | No admin rights. Requires one hook per webview backend: WebView2 `ServerCertificateErrorDetected`, WKWebView `didReceiveAuthenticationChallenge`, WebKitGTK `load-failed-with-tls-errors`. The desktop app already owns this plumbing (`desktop_app/attach.zig`, `webview_lib.zig`). |
| Install a local CA into the OS trust store | Best UX (no interstitial anywhere) but needs elevation / `security add-trusted-cert` / `certutil` — admin prompts. |
| Ship a fixed dev cert in the repo | Simple, but a shared private key in a public repo is a real footgun (anyone can MITM localhost). Only acceptable as a dev-only, loudly-documented default. |

**Recommendation:** generate a self-signed cert (EC P-256, 1-year, SAN
`DNS:localhost, IP:127.0.0.1`) at first run into
`$XDG_DATA_HOME/nalar/tls/` (Windows: `%LOCALAPPDATA%\nalar\tls\`), mode 0600,
plus the webview accept-hook. For plain browsers, print a one-line "trust this
cert once" hint.

### D4 — Scope of the refactor: an I/O indirection, not a rewrite

`ConnectionReader`, `http2/server.zig` and the h1 write path call
`read/write` on a raw `SocketFd` today. TLS needs them to run over `SSL*`.

```zig
pub const Stream = union(enum) {
    plain: SocketFd,
    tls: *TlsConn,
    pub fn read(self: Stream, buf: []u8) !usize;
    pub fn writeAll(self: Stream, bytes: []const u8) !void;
    pub fn close(self: Stream) void;
};
```
* `ConnectionReader.init(alloc, stream)` instead of `fd`.
* `GinwaServer.sendToClient(stream, bytes)`; keep the existing `fd` wrapper for
  the pre-TLS call sites so **h1 wire bytes stay identical**.
* `http2/server.zig::serveConnection(server, stream, alloc, initial, opts)`.

The alternative (duplicating the accept loop for TLS) would double the code paths
that must stay in sync — rejected.

### D5 — Flag surface

`--tls <cert.pem,key.pem>` (explicit files, for users who have their own) and
`--tls-selfsigned` (generate/load the app-data cert). Default **off**. ALPN list:
`h2` first, then `http/1.1`. h2c stays available for non-browser clients.

---

## 1. What the code will look like

| File | Change |
|---|---|
| **NEW** `src/modules/custom_http_server/src/tls.zig` | Thin OpenSSL bindings: `Ctx` (SSL_CTX + ALPN select callback), `Conn` (SSL_new/accept/read/write/shutdown), `Certificate.generateSelfSigned(...)`, `alpnSelected()` |
| **NEW** `src/modules/custom_http_server/src/stream.zig` | The `Stream` union + `read`/`writeAll`/`close` |
| `connection_reader.zig` | Take a `Stream` instead of `SocketFd` |
| `http_server.zig` | `use_tls` config; TLS handshake right after `accept`; ALPN dispatch (`h2` → h2 driver, else h1); `sendToClient(stream, …)` overload |
| `http2/server.zig` | `serveConnection(stream, …)`; `h2` over TLS keeps the same driver (h2 has no cleartext-only concepts) |
| `src/main.zig` | `--tls`, `--tls-selfsigned`, cert path resolution, startup log |
| `build.zig` (module + root) | optional `linkSystemLibrary("ssl"/"crypto")` behind `-Dtls=openssl` |
| `src/apps/desktop_app/` | webview cert-accept hook (WebView2 / WKWebView / WebKitGTK) |
| `docs/http2-tls.md` | design + cert story + "trust once" instructions |

## 2. Tasks (TDD, one commit each)

* **T1** `tls.zig`: `Ctx.init(cert_pem, key_pem, alpn)` + `alpnSelected()` unit tests
  against a self-signed cert generated in-test.
* **T2** `Certificate.generateSelfSigned` (EC P-256, SAN localhost/127.0.0.1):
  test asserts the PEM round-trips through OpenSSL's parser and that the SANs are
  present; file is written 0600 and reused on the next run.
* **T3** `stream.zig` + `ConnectionReader` over `Stream`; existing reader tests
  keep passing over the `plain` variant (no behaviour change).
* **T4** `http_server.zig`: TLS handshake + ALPN dispatch. Tests: ALPN `h2` →
  h2 SETTINGS frame; ALPN `http/1.1` → byte-identical h1 response; no ALPN → h1.
* **T5** `--tls-selfsigned` + `--tls` flags; startup log names the ALPN result.
* **T6** Functional tests (`tests/functional/http2_tls_test.py`): `curl --http2
  --cacert <cert>` over `https://127.0.0.1` → `http_version=2`; `curl -k`; h1 over
  TLS unchanged; bad cert path → clear error; `--tls` off → plaintext still works.
* **T7** `desktop_app` cert-accept hook + flag to launch the webview over https.
* **T8** (part B, mandatory before the app flips) **streaming over h2**:
  `SseManager` per-stream sink + `END_STREAM` instead of `0\r\n\r\n`; SSE works
  over h2; the 501 goes away. Functional: `curl --http2 -N https://…/api/events`
  streams events.
* **T9** docs + changelog + full gates (root `zig build test`, functional suite,
  cross-compile for linux/windows/macos).

## 3. Risks

| Risk | Mitigation |
|---|---|
| **Enabling TLS breaks SSE** (browser uses h2 for everything) | D2 ordering: T8 before any app-side flip; the app flip is a separate, revertable flag (D5). |
| OpenSSL on Windows/macOS in the module build | Keep TLS behind a build flag; reuse the existing system-deps probe + vendored archives; compile-check all three targets in CI. |
| Webview cert interstitial differs per backend | T7 handles each of the three backends explicitly; document the "trust once" fallback. |
| h1 byte-drift from the `Stream` refactor | The `plain` variant must reproduce today's syscalls exactly; existing byte-level tests (SSE chunk framing, `toBytes`, static files) are the guard. |
| Self-signed key on disk is a secret | 0600, generated locally, never logged; never ship a fixed key (D3). |
| ALPN spoofing / downgrade | ALPN is advisory; we serve h2 only when the client asks for it and we never fall back mid-connection. |
